// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-024",
    .severity = .warn,
    .title = "Single source fanning to multiple synchronizers",
    .doc =
    \\One source bit reaches two or more synchronizer chains: each
    \\chain resolves metastability on its own edge, so the set only
    \\holds when the destinations never recombine what they latched
    \\apart. CDC-005 proves the recombination; this rule flags the
    \\fanout itself for the independence judgement.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// Candidates mirror CDC-005; they group by source bit alone, since
// fanout across different domains still resolves independently.
pub const Accum = struct {
    groups: std.AutoHashMapUnmanaged(usize, std.AutoHashMapUnmanaged(u32, Group)) = .empty,
};

const Group = struct {
    dsts: std.AutoHashMapUnmanaged(usize, void) = .empty,
    clks: std.StringHashMapUnmanaged(void) = .empty,
};

pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var acc = Accum{};
    for (ctx.crossings) |x| try accumulate(&acc, ctx, x);
    return finish(&acc, ctx);
}

pub fn accumulate(acc: *Accum, ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!void {
    if (!try isCandidate(ctx, x)) return;
    const sc = x.src.cell.?;
    const dc = x.dst.cell.?;
    const outer = try acc.groups.getOrPut(ctx.range_alloc, sc);
    if (!outer.found_existing) outer.value_ptr.* = .empty;
    const inner = try outer.value_ptr.getOrPut(ctx.range_alloc, x.src.bit);
    if (!inner.found_existing) inner.value_ptr.* = .{};
    try inner.value_ptr.dsts.put(ctx.range_alloc, dc, {});
    const cs = try inner.value_ptr.clks.getOrPut(ctx.range_alloc, x.dst_clk);
    // Clock strings copy out on insert: probes borrow the
    // crossing, but the accumulator outlives the batch.
    if (!cs.found_existing) cs.key_ptr.* = try ctx.range_alloc.dupe(u8, x.dst_clk);
}

pub fn finish(acc: *Accum, ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var keys = std.ArrayListUnmanaged(Key).empty;
    var oit = acc.groups.iterator();
    while (oit.next()) |oe| {
        var iit = oe.value_ptr.iterator();
        while (iit.next()) |ie| {
            if (ie.value_ptr.dsts.count() < 2) continue;
            try keys.append(ctx.tmp, .{ .src = oe.key_ptr.*, .bit = ie.key_ptr.*, .group = ie.value_ptr });
        }
    }
    std.mem.sort(Key, keys.items, {}, struct {
        fn less(_: void, a: Key, b: Key) bool {
            if (a.src != b.src) return a.src < b.src;
            return a.bit < b.bit;
        }
    }.less);
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    for (keys.items) |k| {
        try out.append(ctx.tmp, try fire(ctx, k));
    }
    return out.toOwnedSlice(ctx.tmp);
}

const Key = struct {
    src: usize,
    bit: u32,
    group: *Group,
};

fn isCandidate(ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!bool {
    if (registry.unknownSide(x)) return false;
    if (!x.async_per_sdc) return false;
    if (x.kind != .flop_flop_bit) return false;
    if (ctx.isBusMember(x)) return false;
    if (!std.mem.eql(u8, x.dst.port, "D")) return false;
    const dc = x.dst.cell orelse return false;
    if (x.src.cell == null) return false;
    const dt = ctx.mod.cells[dc].type;
    if (!clock.cells.isSequential(dt) or clock.cells.isLatch(dt)) return false;
    const depth = try ctx.table.chainDepth(ctx.mod, dc, x.dst_clk);
    return depth.depth >= 2;
}

fn fire(ctx: *context.Context, k: Key) error{OutOfMemory}!finding.Finding {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    var clocks = std.ArrayListUnmanaged([]const u8).empty;
    var dit = k.group.dsts.iterator();
    while (dit.next()) |e| try names.append(ctx.tmp, ctx.mod.cells[e.key_ptr.*].name);
    var cit = k.group.clks.iterator();
    while (cit.next()) |e| try clocks.append(ctx.tmp, e.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    std.mem.sort([]const u8, clocks.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    const joined_names = try std.mem.join(ctx.tmp, ", ", names.items);
    const joined_clks = try std.mem.join(ctx.tmp, ", ", clocks.items);
    const message = try std.fmt.allocPrint(ctx.tmp, "fanout to {d} synchronizers: source {s} reaches independent sync chains in domain{s} {s} (chain heads: {s}); each chain resolves metastability on its own edge, so confirm the destinations never recombine the separately-resolved values", .{ names.items.len, ctx.mod.cells[k.src].name, if (clocks.items.len == 1) "" else "s", joined_clks, joined_names });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = ctx.mod.cells[k.src].name,
        .message = message,
    };
}
