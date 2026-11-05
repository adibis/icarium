const std = @import("std");
const clock = @import("icarium").clock;
const ir = @import("icarium").ir;
const reset = @import("icarium").reset;
const sdc = @import("icarium").sdc;
const sync = @import("icarium").sync;

test "hints load polarities and syncs, reject mistyped files" {
    const doc = "{\"polarities\": {\"rst_n\": \"low\", \"rst\": \"high\"}, \"syncs\": [\"a\", \"b\"]}";
    var h = try sync.hints.load(std.testing.allocator, doc);
    defer h.deinit();
    try std.testing.expect(h.polarities.get("rst_n") == .low);
    try std.testing.expect(h.polarities.get("rst") == .high);
    try std.testing.expectEqual(@as(usize, 2), h.syncs.len);

    try std.testing.expectError(error.BadHints, sync.hints.load(std.testing.allocator, "nope"));
    const bad_pol = "{\"polarities\": {\"rst_n\": \"sometimes\"}}";
    try std.testing.expectError(error.BadHints, sync.hints.load(std.testing.allocator, bad_pol));
    const bad_syncs = "{\"syncs\": \"a\"}";
    try std.testing.expectError(error.BadHints, sync.hints.load(std.testing.allocator, bad_syncs));
}

test "hints merge into marks and win disagreements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try ir.load.loadFromSlice(arena.allocator(), netlist, null);
    var marks = try sync.attrs.collect(arena.allocator(), &mod);
    // The RTL declares low; the hint says high and must prevail.
    try std.testing.expect(marks.resetPolarity("rst_n") == .low);
    try std.testing.expect(!marks.hasResetSync("dst"));
    var h = try sync.hints.load(arena.allocator(), "{\"polarities\": {\"rst_n\": \"high\"}, \"syncs\": [\"dst\"]}");
    try marks.applyHints(&h);
    try std.testing.expect(marks.resetPolarity("rst_n") == .high);
    try std.testing.expect(marks.hasResetSync("dst"));
}

test "hints steer the reset view past attributes" {
    var l = try loadView("{\"polarities\": {\"rst_n\": \"high\"}}");
    defer freeView(&l);
    try std.testing.expectEqual(@as(usize, 1), l.view.flops.len);
    try std.testing.expect(l.view.flops[0].async[0].polarity == .high);
}

const ViewLoaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    clock_asg: clock.trace.Assignment,
    hints: sync.hints.Hints,
    view: reset.trace.View,
};

fn loadView(hints_doc: []const u8) !ViewLoaded {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    errdefer mod.deinit();
    var sdc_mod = try sdc.model.build(std.testing.allocator, &[_]sdc.commands.Parsed{});
    errdefer sdc_mod.deinit();
    var clock_asg = try clock.trace.assign(std.testing.allocator, &mod, &sdc_mod);
    errdefer clock_asg.deinit();
    var hints = try sync.hints.load(std.testing.allocator, hints_doc);
    errdefer hints.deinit();
    const view = try reset.trace.assign(std.testing.allocator, &mod, &clock_asg, &hints.polarities);
    return .{ .mod = mod, .sdc_mod = sdc_mod, .clock_asg = clock_asg, .hints = hints, .view = view };
}

fn freeView(l: *ViewLoaded) void {
    l.view.deinit();
    l.hints.deinit();
    l.clock_asg.deinit();
    l.sdc_mod.deinit();
    l.mod.deinit();
}

const netlist =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "rst_n": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "dst": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0", "ARST_VALUE": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "ARST": [3], "Q": [12]}
    \\        }
    \\      },
    \\      "netnames": {
    \\        "rst_n": {"hide_name": 0, "bits": [3], "attributes": {"reset_polarity": "low"}}
    \\      }
    \\    }
    \\  }
    \\}
;
