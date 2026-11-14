// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("icarium").clock;
const crossing = @import("icarium").crossing;
const ir = @import("icarium").ir;
const rule = @import("icarium").rule;
const reset = @import("icarium").reset;
const sdc = @import("icarium").sdc;
const sync = @import("icarium").sync;

const Loaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    clock_asg: clock.trace.Assignment,
    report: crossing.enumerate.Report,
    table: sync.table.Table,
    marks: sync.attrs.Marks,
    reset_view: reset.trace.View,
    reset_syncs: reset.chains.Syncs,
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
    var report = try crossing.enumerate.enumerate(std.testing.allocator, &mod, &clock_asg, &sdc_mod);
    errdefer report.deinit();
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
        .report = report,
        .table = table,
        .marks = marks,
        .reset_view = reset_view,
        .reset_syncs = reset_syncs,
    };
}

fn freeAll(l: *Loaded) void {
    l.reset_syncs.deinit();
    l.reset_view.deinit();
    l.marks.deinit();
    l.table.deinit();
    l.report.deinit();
    l.clock_asg.deinit();
    l.sdc_mod.deinit();
    l.mod.deinit();
}

// Gross bytes through a retain allocator: frees never
// subtract, since the production child is an arena whose
// free is a no-op. Duplicates must not move this counter.
const Gross = struct {
    child: std.mem.Allocator,
    gross: usize = 0,

    fn allocator(self: *Gross) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Gross = @ptrCast(@alignCast(ctx));
        const out = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.gross += len;
        return out;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Gross = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
        self.gross += new_len -| memory.len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Gross = @ptrCast(@alignCast(ctx));
        const out = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.gross += new_len -| memory.len;
        return out;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Gross = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
    }
};

const two_sdc_typed =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports d]
;

const bare =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [11]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [11]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

// One batch pass over the report tiled K times: every tile
// refires the same CDC-001, so K=100 must retain barely more
// than K=10. Poison proves kept strings left tmp for alloc.
fn runTiled(l: *Loaded, k: usize, only_rule: ?[]const u8) !struct { gross: usize, kept: usize } {
    const base = l.report.crossings;
    const tiled = try std.testing.allocator.alloc(crossing.enumerate.Crossing, base.len * k);
    defer std.testing.allocator.free(tiled);
    for (0..k) |i| @memcpy(tiled[i * base.len ..][0..base.len], base);

    var retain_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer retain_arena.deinit();
    var gross = Gross{ .child = retain_arena.allocator() };
    const tmp_buf = try std.testing.allocator.alloc(u8, 4 << 20);
    defer std.testing.allocator.free(tmp_buf);
    var tmp_fba = std.heap.FixedBufferAllocator.init(tmp_buf);
    var ctx = rule.context.Context{
        .mod = &l.mod,
        .model = &l.sdc_mod,
        .crossings = tiled,
        .table = &l.table,
        .marks = &l.marks,
        .reset_view = &l.reset_view,
        .reset_syncs = &l.reset_syncs,
        .buses = &.{},
        .cfg = .{},
        .tmp = tmp_fba.allocator(),
        .range_alloc = gross.allocator(),
        .alloc = gross.allocator(),
    };
    var run = rule.registry.Run.init(gross.allocator(), std.testing.allocator);
    defer run.deinit();
    const only: ?[]const []const u8 = if (only_rule) |r| &[_][]const u8{r} else null;
    try run.runPass(&ctx, only, null, .batch);
    try run.runRangeBatch(&ctx, only, null);
    try run.endRange(&ctx, only, null);
    try std.testing.expectEqual(@as(usize, 1), run.out.items.len);
    const snap = try std.testing.allocator.dupe(u8, run.out.items[0].message);
    defer std.testing.allocator.free(snap);
    @memset(tmp_buf, 0xAA);
    try std.testing.expectEqualStrings(snap, run.out.items[0].message);
    return .{ .gross = gross.gross, .kept = run.out.items.len };
}

test "duplicate fires retain once, not per fire" {
    var l = try loadAll(bare, two_sdc_typed);
    defer freeAll(&l);
    const small = try runTiled(&l, 10, "CDC-001");
    const big = try runTiled(&l, 100, "CDC-001");
    try std.testing.expectEqual(@as(usize, 1), small.kept);
    try std.testing.expectEqual(@as(usize, 1), big.kept);
    try std.testing.expect(big.gross < 3 * small.gross);
}

test "all rules retain bounded per duplicate tile" {
    var l = try loadAll(bare, two_sdc_typed);
    defer freeAll(&l);
    const small = try runTiled(&l, 10, null);
    const big = try runTiled(&l, 100, null);
    try std.testing.expect(big.gross < 3 * small.gross);
}

// Enabled bus, gated in its own domain: CDC-004 walks the
// enable fanin for every tile, proves gating, and fires
// nothing. Walk garbage must not scale with tile count.
const gated =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk_a": {"direction": "input", "bits": [2]},
    \\        "clk_b": {"direction": "input", "bits": [3]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [30, 31], "Q": [10, 11]}
    \\        },
    \\        "en1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [40], "Q": [41]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "EN": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10, 11], "EN": [41], "Q": [20, 21]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

// Batch-tmp gross over K tiles: walks that memoize stay
// flat, walks that rerun grow with the tile count. Fires
// stay out of the signal; the fixture proves gating.
fn runGross(json: []const u8, sdc_text: ?[]const u8, k: usize, only_rule: ?[]const u8) !usize {
    var l = try loadAll(json, sdc_text);
    defer freeAll(&l);
    const base = l.report.crossings;
    const tiled = try std.testing.allocator.alloc(crossing.enumerate.Crossing, base.len * k);
    defer std.testing.allocator.free(tiled);
    for (0..k) |i| @memcpy(tiled[i * base.len ..][0..base.len], base);

    var keep_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer keep_arena.deinit();
    var tmp_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp_arena.deinit();
    var tmp_gross = Gross{ .child = tmp_arena.allocator() };
    var ctx = rule.context.Context{
        .mod = &l.mod,
        .model = &l.sdc_mod,
        .crossings = tiled,
        .table = &l.table,
        .marks = &l.marks,
        .reset_view = &l.reset_view,
        .reset_syncs = &l.reset_syncs,
        .buses = &.{},
        .cfg = .{},
        .tmp = tmp_gross.allocator(),
        .range_alloc = keep_arena.allocator(),
        .alloc = keep_arena.allocator(),
    };
    var run = rule.registry.Run.init(keep_arena.allocator(), std.testing.allocator);
    defer run.deinit();
    const only: ?[]const []const u8 = if (only_rule) |r| &[_][]const u8{r} else null;
    try run.runPass(&ctx, only, null, .batch);
    try run.runRangeBatch(&ctx, only, null);
    try run.endRange(&ctx, only, null);
    try std.testing.expectEqual(@as(usize, 0), run.out.items.len);
    return tmp_gross.gross;
}

test "CDC-004 gating walks memoize across duplicate tiles" {
    const small = try runGross(gated, bus_sdc, 10, "CDC-004");
    const big = try runGross(gated, bus_sdc, 100, "CDC-004");
    // A fully memoized walk touches tmp never: zero must
    // stay zero, or the ratio below divides by nothing.
    if (small == 0) {
        try std.testing.expectEqual(@as(usize, 0), big);
    } else {
        try std.testing.expect(big < 3 * small);
    }
}

const bus_sdc =
    \\create_clock -name clk_a -period 10 [get_ports clk_a]
    \\create_clock -name clk_b -period 7 [get_ports clk_b]
    \\set_clock_groups -asynchronous -group {clk_a} -group {clk_b}
;

// Clock muxes with comb trees behind select: CDC-010 walks
// each mux once, and walk garbage must die per mux rather
// than accumulate across them. Trees hold no flops, so the
// rule walks every cone and fires nothing.
fn clockForest(muxes: usize, depth: usize) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    const w = &buf.writer;
    // Bits stay compact and sequential: sparse numbering would
    // size the loader's dense bit-indexed tables, not the walks.
    var next_bit: usize = 100;
    const ncells: usize = (@as(usize, 1) << @intCast(depth)) - 1;
    const ys = try std.testing.allocator.alloc(usize, ncells);
    defer std.testing.allocator.free(ys);
    try w.writeAll("{\"modules\":{\"top\":{\"ports\":{");
    try w.writeAll("\"clk_a\":{\"direction\":\"input\",\"bits\":[2]},");
    try w.writeAll("\"clk_b\":{\"direction\":\"input\",\"bits\":[3]}},\"cells\":{");
    var first = true;
    for (0..muxes) |m| {
        for (ys) |*y| {
            y.* = next_bit;
            next_bit += 1;
        }
        for (0..ncells) |i| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("\"t{d}_{d}\":{{\"type\":\"$and\",\"port_directions\":{{\"A\":\"input\",\"B\":\"input\",\"Y\":\"output\"}},\"connections\":{{", .{ m, i });
            const la = 2 * i + 1;
            const lb = 2 * i + 2;
            if (la < ncells) {
                try w.print("\"A\":[{d}],\"B\":[{d}],\"Y\":[{d}]}}}}", .{ ys[la], ys[lb], ys[i] });
            } else {
                const a = next_bit;
                next_bit += 1;
                const b = next_bit;
                next_bit += 1;
                try w.print("\"A\":[{d}],\"B\":[{d}],\"Y\":[{d}]}}}}", .{ a, b, ys[i] });
            }
        }
        const my = next_bit;
        next_bit += 1;
        const dd = next_bit;
        next_bit += 1;
        const dq = next_bit;
        next_bit += 1;
        try w.print(",\"mux{d}\":{{\"type\":\"$mux\",\"port_directions\":{{\"A\":\"input\",\"B\":\"input\",\"S\":\"input\",\"Y\":\"output\"}},\"connections\":{{\"A\":[2],\"B\":[3],\"S\":[{d}],\"Y\":[{d}]}}}}", .{ m, ys[0], my });
        try w.print(",\"dst{d}\":{{\"type\":\"$dff\",\"port_directions\":{{\"CLK\":\"input\",\"D\":\"input\",\"Q\":\"output\"}},\"connections\":{{\"CLK\":[{d}],\"D\":[{d}],\"Q\":[{d}]}}}}", .{ m, my, dd, dq });
    }
    try w.writeAll("}}}}");
    return buf.toOwnedSlice();
}

fn runOnceGross(muxes: usize) !usize {
    const json = try clockForest(muxes, 6);
    defer std.testing.allocator.free(json);
    var l = try loadAll(json, bus_sdc);
    defer freeAll(&l);
    var tmp_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tmp_arena.deinit();
    var tmp_gross = Gross{ .child = tmp_arena.allocator() };
    var ctx = rule.context.Context{
        .mod = &l.mod,
        .model = &l.sdc_mod,
        .crossings = &.{},
        .table = &l.table,
        .marks = &l.marks,
        .reset_view = &l.reset_view,
        .reset_syncs = &l.reset_syncs,
        .buses = &.{},
        .cfg = .{},
        .tmp = tmp_gross.allocator(),
        .range_alloc = std.testing.allocator,
        .alloc = std.testing.allocator,
    };
    const rl = rule.registry.find("CDC-010").?;
    const fs = try rl.check_all.?(&ctx);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
    return tmp_gross.gross;
}

test "CDC-010 walks die per clock cell" {
    const small = try runOnceGross(10);
    const big = try runOnceGross(100);
    if (small == 0) {
        try std.testing.expectEqual(@as(usize, 0), big);
    } else {
        try std.testing.expect(big < 3 * small);
    }
}
