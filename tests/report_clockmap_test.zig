const std = @import("std");
const clock = @import("icarium").clock;
const crossing = @import("icarium").crossing;
const ir = @import("icarium").ir;
const report = @import("icarium").report;
const rule = @import("icarium").rule;
const sdc = @import("icarium").sdc;
const sync = @import("icarium").sync;

const netlist =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "attributes": {"src": "top.sv:4.3-4.20"},
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [6]}
    \\        },
    \\        "mid": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [6], "Q": [7]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [7], "Q": [12]}
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
    \\set_input_delay -clock ca 1.0 [get_ports d]
;

const Loaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    clock_asg: clock.trace.Assignment,
    xrep: crossing.enumerate.Report,
    table: sync.table.Table,
    marks: sync.attrs.Marks,
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
    return .{
        .mod = mod,
        .sdc_mod = sdc_mod,
        .clock_asg = clock_asg,
        .xrep = xrep,
        .table = table,
        .marks = marks,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
}

fn freeAll(l: *Loaded) void {
    l.arena.deinit();
    l.marks.deinit();
    l.table.deinit();
    l.xrep.deinit();
    l.clock_asg.deinit();
    l.sdc_mod.deinit();
    l.mod.deinit();
}

fn emit(l: *Loaded, fs: []rule.finding.Finding) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try report.clockmap.writeClockMap(std.testing.allocator, &aw.writer, &l.mod, &l.sdc_mod, &l.clock_asg, &l.xrep, &l.table, &l.marks, fs, "0.1.0-dev");
    return std.testing.allocator.dupe(u8, aw.written());
}

test "clock map carries clocks, domains, and 2ff verdicts" {
    var l = try loadAll();
    defer freeAll(&l);
    const bytes = try emit(&l, &.{});
    defer std.testing.allocator.free(bytes);
    var parse_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parse_arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, parse_arena.allocator(), bytes, .{});
    const root = parsed.object;
    try std.testing.expectEqualStrings("1.0", root.get("schema_version").?.string);
    try std.testing.expectEqualStrings("top", root.get("design").?.object.get("top").?.string);

    const clocks = root.get("clocks").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), clocks.len);
    try std.testing.expectEqualStrings("ca", clocks[0].object.get("name").?.string);
    const period = clocks[0].object.get("period").?;
    const period_f: f64 = switch (period) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => unreachable,
    };
    try std.testing.expectEqual(@as(f64, 10), period_f);
    try std.testing.expectEqualStrings("ca", clocks[0].object.get("ports").?.array.items[0].string);

    const groups = root.get("clock_groups").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqualStrings("asynchronous", groups[0].object.get("kind").?.string);

    const flops = root.get("flop_domains").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), flops.len);
    const src = flops[2].object;
    try std.testing.expectEqualStrings("src", src.get("cell").?.string);
    try std.testing.expectEqualStrings("ca", src.get("clock").?.string);
    try std.testing.expectEqualStrings("top.sv", src.get("location").?.object.get("file").?.string);

    const ports = root.get("port_domains").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), ports.len);
    try std.testing.expectEqualStrings("d", ports[0].object.get("port").?.string);

    var saw_2ff = false;
    for (root.get("crossings").?.array.items) |x| {
        const o = x.object;
        if (std.mem.eql(u8, o.get("dst").?.object.get("name").?.string, "mid") and
            o.get("async_per_sdc").?.bool)
        {
            try std.testing.expectEqualStrings("2ff", o.get("synchronizer").?.string);
            saw_2ff = true;
        }
    }
    try std.testing.expect(saw_2ff);
}

test "clock map emission is byte-stable" {
    var l = try loadAll();
    defer freeAll(&l);
    const a = try emit(&l, &.{});
    defer std.testing.allocator.free(a);
    const b = try emit(&l, &.{});
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
}
