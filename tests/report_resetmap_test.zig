// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("icarium").clock;
const crossing = @import("icarium").crossing;
const ir = @import("icarium").ir;
const report = @import("icarium").report;
const reset = @import("icarium").reset;
const sdc = @import("icarium").sdc;
const sync = @import("icarium").sync;

// A synced port in ca, a foreign flopped reset into cb: one
// chain, one async-deassert crossing, no polarity overrides.
const netlist =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "rst": {"direction": "input", "bits": [4]},
    \\        "da": {"direction": "input", "bits": [5]},
    \\        "db": {"direction": "input", "bits": [6]},
    \\        "qa": {"direction": "output", "bits": [12]},
    \\        "qb": {"direction": "output", "bits": [13]}
    \\      },
    \\      "cells": {
    \\        "ahead": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0", "ARST_VALUE": "0"},
    \\          "attributes": {"src": "top.sv:4.3-4.20"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": ["1"], "ARST": [4], "Q": [7]}
    \\        },
    \\        "atail": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0", "ARST_VALUE": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [7], "ARST": [4], "Q": [8]}
    \\        },
    \\        "asrc": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0", "ARST_VALUE": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [5], "ARST": [8], "Q": [9]}
    \\        },
    \\        "bcon": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0", "ARST_VALUE": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [6], "ARST": [9], "Q": [13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const sdc_text =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports da]
    \\set_input_delay -clock cb 1.0 [get_ports db]
;

const Loaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    clock_asg: clock.trace.Assignment,
    xrep: crossing.enumerate.Report,
    table: sync.table.Table,
    marks: sync.attrs.Marks,
    reset_view: reset.trace.View,
    reset_syncs: reset.chains.Syncs,
    arena: std.heap.ArenaAllocator,
};

fn loadAll() !Loaded {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    errdefer mod.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var warns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    const cmds = try sdc.tokens.parseCommands(arena.allocator(), sdc_text, &warns);
    var parsed: std.ArrayListUnmanaged(sdc.commands.Parsed) = .empty;
    for (cmds) |c| try parsed.append(arena.allocator(), try sdc.commands.parse(arena.allocator(), c, &warns));
    var sdc_mod = try sdc.model.build(std.testing.allocator, parsed.items);
    errdefer sdc_mod.deinit();
    var awarns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    var clock_asg = try clock.trace.assign(std.testing.allocator, &mod, &sdc_mod, &awarns);
    errdefer clock_asg.deinit();
    var xrep = try crossing.enumerate.enumerate(std.testing.allocator, &mod, &clock_asg, &sdc_mod);
    errdefer xrep.deinit();
    var table = try sync.table.build(std.testing.allocator, &mod, &clock_asg);
    errdefer table.deinit();
    var marks = try sync.attrs.collect(std.testing.allocator, &mod);
    errdefer marks.deinit();
    var reset_view = try reset.trace.assign(std.testing.allocator, &mod, &clock_asg, null);
    errdefer reset_view.deinit();
    var reset_syncs = try reset.chains.find(std.testing.allocator, &mod, &reset_view, &table.domains, &marks.reset_syncs);
    errdefer reset_syncs.deinit();
    return .{
        .mod = mod,
        .sdc_mod = sdc_mod,
        .clock_asg = clock_asg,
        .xrep = xrep,
        .table = table,
        .marks = marks,
        .reset_view = reset_view,
        .reset_syncs = reset_syncs,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
}

fn freeAll(l: *Loaded) void {
    l.arena.deinit();
    l.reset_syncs.deinit();
    l.reset_view.deinit();
    l.marks.deinit();
    l.table.deinit();
    l.xrep.deinit();
    l.clock_asg.deinit();
    l.sdc_mod.deinit();
    l.mod.deinit();
}

fn emit(l: *Loaded) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try report.resetmap.writeResetMap(std.testing.allocator, &aw.writer, &l.mod, &l.reset_view, &l.reset_syncs, &l.table, &l.marks, "0.1.0-dev");
    return std.testing.allocator.dupe(u8, aw.written());
}

test "reset map carries sources, chains, and crossings" {
    var l = try loadAll();
    defer freeAll(&l);
    const bytes = try emit(&l);
    defer std.testing.allocator.free(bytes);
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, parse_arena.allocator(), bytes, .{});
    const root = parsed.object;
    try std.testing.expectEqualStrings("1.0", root.get("schema_version").?.string);

    const syncs = root.get("reset_synchronizers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), syncs.len);
    try std.testing.expectEqualStrings("atail", syncs[0].object.get("tail").?.string);
    try std.testing.expectEqualStrings("ca", syncs[0].object.get("clock").?.string);
    try std.testing.expectEqualStrings("1", syncs[0].object.get("head_d").?.string);

    const sources = root.get("reset_sources").?.array.items;
    var saw_tail = false;
    var saw_port = false;
    for (sources) |s| {
        const o = s.object;
        if (std.mem.eql(u8, o.get("name").?.string, "atail")) {
            try std.testing.expect(o.get("via_synchronizer").?.bool);
            try std.testing.expectEqualStrings("ca", o.get("clock").?.string);
            saw_tail = true;
        }
        if (std.mem.eql(u8, o.get("name").?.string, "rst")) {
            try std.testing.expectEqualStrings("port", o.get("source").?.string);
            try std.testing.expect(!o.get("via_synchronizer").?.bool);
            saw_port = true;
        }
    }
    try std.testing.expect(saw_tail and saw_port);

    const rows = root.get("flop_resets").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), rows.len);

    const crossings = root.get("reset_crossings").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), crossings.len);
    const x = crossings[0].object;
    try std.testing.expectEqualStrings("async-deassert", x.get("kind").?.string);
    try std.testing.expectEqualStrings("bcon", x.get("cell").?.string);
    try std.testing.expectEqualStrings("cb", x.get("flop_clock").?.string);
    try std.testing.expectEqualStrings("asrc", x.get("reset").?.string);
}

test "reset map emission is byte-stable" {
    var l = try loadAll();
    defer freeAll(&l);
    const a = try emit(&l);
    defer std.testing.allocator.free(a);
    const b = try emit(&l);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}
