// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-019",
    .severity = .warn,
    .title = "Independently-synced one-hot decode across CDC",
    .doc =
    \\One comb decoder fans to two or more 1-bit source flops that
    \\cross to the same domain: lanes change together upstream but
    \\resolve apart, so the destination can sample combinations the
    \\encoder never emits. Gray-code the source or handshake it.
    ,
    .honors = &.{ "cdc_gray", "cdc_static", "cdc_sync" },
    .check_all = checkAll,
};

// One finding per (decoder, dst clock) group with two or more
// lanes. A marked lane vouches the whole group; a flopped or
// narrow driver was never a decoder, so it never groups.
pub const Accum = struct {
    groups: std.AutoHashMapUnmanaged(usize, std.StringHashMapUnmanaged(Group)) = .empty,
};

pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var acc = Accum{};
    for (ctx.crossings) |x| try accumulate(&acc, ctx, x);
    return finish(&acc, ctx);
}

pub fn accumulate(acc: *Accum, ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!void {
    const groups = &acc.groups;
    switch (x.kind) {
        .flop_flop_bit, .port_flop, .port_flop_untyped => {},
        else => return,
    }
    if (!std.mem.eql(u8, x.dst.port, "D")) return;
    const sc = x.src.cell orelse return;
    const dc = x.dst.cell orelse return;
    if (clock.cells.isLatch(ctx.mod.cells[sc].type)) return;
    if (clock.cells.isLatch(ctx.mod.cells[dc].type)) return;
    if (std.mem.eql(u8, x.dst_clk, "unknown")) return;
    if (std.mem.eql(u8, x.src_clk, x.dst_clk)) return;
    const sd = ctx.mod.cells[sc].portBits("D") orelse return;
    if (sd.len != 1 or sd[0] != .sig) return;
    const drv = ctx.mod.driver_of.get(sd[0].sig) orelse return;
    const di = drv.cell orelse return;
    if (!std.mem.eql(u8, drv.port, "Y")) return;
    const dt = ctx.mod.cells[di].type;
    if (clock.cells.isSequential(dt) and !clock.cells.isLatch(dt)) return;
    const y = ctx.mod.cells[di].portBits("Y") orelse return;
    var wide = false;
    var int_bits: usize = 0;
    for (y) |b| {
        if (b == .sig) int_bits += 1;
    }
    if (int_bits >= 2) wide = true;
    if (!wide) return;
    const outer = try groups.getOrPut(ctx.alloc, di);
    if (!outer.found_existing) outer.value_ptr.* = .empty;
    const inner = try outer.value_ptr.getOrPut(ctx.alloc, x.dst_clk);
    // Clock keys copy out: the accumulator outlives the batch
    // crossings they borrow from.
    if (!inner.found_existing) {
        inner.value_ptr.* = .{ .lanes = .empty, .suppressed = false };
        inner.key_ptr.* = try ctx.alloc.dupe(u8, x.dst_clk);
    }
    const src_name = ctx.mod.cells[sc].name;
    if (ctx.marks.hasGray(src_name) or
        ctx.marks.hasStatic(src_name) or
        ctx.marks.hasSync(src_name))
    {
        inner.value_ptr.suppressed = true;
        return;
    }
    try inner.value_ptr.lanes.put(ctx.alloc, src_name, ctx.mod.cells[dc].name);
}

pub fn finish(acc: *Accum, ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var keys = std.ArrayListUnmanaged(Key).empty;
    var oit = acc.groups.iterator();
    while (oit.next()) |oe| {
        var iit = oe.value_ptr.iterator();
        while (iit.next()) |ie| {
            if (ie.value_ptr.suppressed) continue;
            if (ie.value_ptr.lanes.count() < 2) continue;
            try keys.append(ctx.tmp, .{ .drv = oe.key_ptr.*, .clk = ie.key_ptr.*, .lanes = ie.value_ptr.lanes });
        }
    }
    std.mem.sort(Key, keys.items, ctx, struct {
        fn less(c: *context.Context, a: Key, b: Key) bool {
            const ak = std.mem.order(u8, c.mod.cells[a.drv].name, c.mod.cells[b.drv].name);
            if (ak != .eq) return ak == .lt;
            return std.mem.order(u8, a.clk, b.clk) == .lt;
        }
    }.less);
    for (keys.items) |k| {
        var names = std.ArrayListUnmanaged([]const u8).empty;
        var lit = k.lanes.iterator();
        while (lit.next()) |le| try names.append(ctx.tmp, le.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        const desc = try laneDesc(ctx, names.items);
        const message = try std.fmt.allocPrint(ctx.tmp, "independently-synced one-hot decode across CDC: comb cell {s} drives {d} separate WIDTH=1 source flops ({s}) that each cross independently to clock domain {s}. The shared driver makes the lanes change together at the source, but each destination sync chain resolves on its own schedule. Fix: gray-code the source or gate the destination sample behind a req/ack handshake.", .{ ctx.mod.cells[k.drv].name, names.items.len, desc, k.clk });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = names.items[0],
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

const Group = struct {
    lanes: std.StringHashMapUnmanaged([]const u8),
    suppressed: bool,
};

const Key = struct {
    drv: usize,
    clk: []const u8,
    lanes: std.StringHashMapUnmanaged([]const u8),
};

// First four lanes, then a total: long decoders stay readable
// without hiding how many lanes take part.
fn laneDesc(ctx: *context.Context, names: [][]const u8) error{OutOfMemory}![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    const show = @min(names.len, 4);
    for (names[0..show], 0..) |n, i| {
        if (i > 0) try buf.appendSlice(ctx.tmp, ", ");
        try buf.appendSlice(ctx.tmp, n);
    }
    if (names.len > 4) {
        const tail = try std.fmt.allocPrint(ctx.tmp, ", ... ({d} lanes total)", .{names.len});
        try buf.appendSlice(ctx.tmp, tail);
    }
    return buf.toOwnedSlice(ctx.tmp);
}
