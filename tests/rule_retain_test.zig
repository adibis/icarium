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
