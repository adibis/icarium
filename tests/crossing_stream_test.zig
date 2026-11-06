const std = @import("std");
const clock = @import("icarium").clock;
const crossing = @import("icarium").crossing;
const ir = @import("icarium").ir;
const sdc = @import("icarium").sdc;

const Loaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    clock_asg: clock.trace.Assignment,
    report: crossing.enumerate.Report,
};

fn loadAll(json: []const u8, sdc_text: ?[]const u8) !Loaded {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, json, null);
    errdefer mod.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var warns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    var sdc_mod: sdc.model.Model = undefined;
    if (sdc_text) |t| {
        const cmds = try sdc.tokens.parseCommands(arena.allocator(), t, &warns);
        var parsed: std.ArrayListUnmanaged(sdc.commands.Parsed) = .empty;
        for (cmds) |c| try parsed.append(arena.allocator(), try sdc.commands.parse(arena.allocator(), c, &warns));
        sdc_mod = try sdc.model.build(std.testing.allocator, parsed.items);
    } else {
        sdc_mod = try sdc.model.build(std.testing.allocator, &[_]sdc.commands.Parsed{});
    }
    errdefer sdc_mod.deinit();
    var awarns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    var clock_asg = try clock.trace.assign(std.testing.allocator, &mod, &sdc_mod, &awarns);
    errdefer clock_asg.deinit();
    const report = try crossing.enumerate.enumerate(std.testing.allocator, &mod, &clock_asg, &sdc_mod);
    return .{ .mod = mod, .sdc_mod = sdc_mod, .clock_asg = clock_asg, .report = report };
}

fn freeAll(l: *Loaded) void {
    l.report.deinit();
    l.clock_asg.deinit();
    l.sdc_mod.deinit();
    l.mod.deinit();
}

const pairs =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk_a": {"direction": "input", "bits": [2]},
    \\        "clk_b": {"direction": "input", "bits": [3]},
    \\        "din": {"direction": "input", "bits": [4]},
    \\        "raw": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "fa": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "fb": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [11]}
    \\        },
    \\        "fc": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [11], "Q": [12]}
    \\        },
    \\        "fd": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [5], "Q": [13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const pairs_sdc =
    \\create_clock -name clk_a -period 10 [get_ports clk_a]
    \\create_clock -name clk_b -period 7 [get_ports clk_b]
    \\set_clock_groups -asynchronous -group {clk_a} -group {clk_b}
    \\set_input_delay -clock clk_a [get_ports din]
;

const bus =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk_a": {"direction": "input", "bits": [2]},
    \\        "clk_b": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [20, 21]}
    \\      },
    \\      "cells": {
    \\        "u_sub.src2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [30, 31], "Q": [10, 11]},
    \\          "attributes": {"src": "bus.sv:1"}
    \\        },
    \\        "g1": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [10], "Y": [12]}
    \\        },
    \\        "n1": {
    \\          "type": "$not",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [12], "Y": [13]}
    \\        },
    \\        "u_sub.dst2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [11, 13], "Q": [20, 21]},
    \\          "attributes": {"src": "bus.sv:9"}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const bus_sdc =
    \\create_clock -name clk_a -period 10 [get_ports clk_a]
    \\create_clock -name clk_b -period 7 [get_ports clk_b]
    \\set_clock_groups -asynchronous -group {clk_a} -group {clk_b}
;

// Batch contract: the union of batch crossings is the report,
// and no source run straddles two batches. IDs compare by
// content, so batch borrows need no copies to verify. The
// callback cannot fail a test (fixed error set), so it counts
// violations and the test asserts zero after the stream.
const Checker = struct {
    want: std.StringHashMapUnmanaged(usize),
    seen_cells: std.AutoHashMapUnmanaged(usize, usize),
    seen_ports: std.StringHashMapUnmanaged(usize),
    batches: usize = 0,
    bad_ids: usize = 0,
    split_runs: usize = 0,
    want_integrity: bool,

    fn onBatch(c: *Checker, batch: crossing.enumerate.Batch) error{OutOfMemory}!void {
        c.batches += 1;
        // Every pair builds one bit crossing; bus records add more.
        if (batch.crossings.len < batch.pairs) c.bad_ids += 1;
        for (batch.crossings) |x| {
            if (c.want.getPtr(x.id)) |left| {
                if (left.* == 0) {
                    c.bad_ids += 1;
                } else left.* -= 1;
            } else c.bad_ids += 1;
            if (!c.want_integrity) continue;
            if (x.src.cell) |sc| {
                const slot = try c.seen_cells.getOrPut(std.testing.allocator, sc);
                if (!slot.found_existing) {
                    slot.value_ptr.* = c.batches;
                } else if (slot.value_ptr.* != c.batches) {
                    c.split_runs += 1;
                }
            } else {
                const slot = try c.seen_ports.getOrPut(std.testing.allocator, x.src.port);
                if (!slot.found_existing) {
                    slot.key_ptr.* = try std.testing.allocator.dupe(u8, x.src.port);
                    slot.value_ptr.* = c.batches;
                } else if (slot.value_ptr.* != c.batches) {
                    c.split_runs += 1;
                }
            }
        }
    }
};

fn checkStream(json: []const u8, sdc_text: ?[]const u8, chunk: usize, budget: usize, want_integrity: bool) !void {
    var l = try loadAll(json, sdc_text);
    defer freeAll(&l);
    var c = Checker{ .want = .empty, .seen_cells = .empty, .seen_ports = .empty, .want_integrity = want_integrity };
    defer c.want.deinit(std.testing.allocator);
    defer c.seen_cells.deinit(std.testing.allocator);
    defer {
        var it = c.seen_ports.iterator();
        while (it.next()) |e| std.testing.allocator.free(e.key_ptr.*);
        c.seen_ports.deinit(std.testing.allocator);
    }
    for (l.report.crossings) |x| {
        const slot = try c.want.getOrPut(std.testing.allocator, x.id);
        slot.value_ptr.* = (if (slot.found_existing) slot.value_ptr.* else 0) + 1;
    }
    try crossing.enumerate.streamBatches(std.testing.allocator, &l.mod, &l.clock_asg, &l.sdc_mod, chunk, budget, &c, Checker.onBatch);
    try std.testing.expect(c.batches > 0);
    try std.testing.expectEqual(@as(usize, 0), c.bad_ids);
    try std.testing.expectEqual(@as(usize, 0), c.split_runs);
    var it = c.want.iterator();
    while (it.next()) |e| try std.testing.expectEqual(@as(usize, 0), e.value_ptr.*);
}

test "streamed batches equal the whole report at one source per chunk" {
    try checkStream(pairs, pairs_sdc, 1, 1000000, true);
}

test "streamed batches equal the whole report at full chunk" {
    try checkStream(pairs, pairs_sdc, 2048, 1000000, true);
}

test "streamed bus groups survive one-source chunks" {
    try checkStream(bus, bus_sdc, 1, 1000000, true);
}

test "streamed dst splits keep every crossing" {
    try checkStream(pairs, pairs_sdc, 2048, 1, false);
}

test "streamed over-budget single dst keeps every crossing" {
    try checkStream(bus, bus_sdc, 2048, 1, false);
}
