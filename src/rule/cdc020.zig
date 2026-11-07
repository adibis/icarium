const std = @import("std");
const bus = @import("bus.zig");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-020",
    .severity = .warn,
    .title = "Sliced-bus reconvergence across CDC",
    .doc =
    \\A multi-bit source register fans lane by lane to two or more
    \\destinations in one domain: each lane resolves apart, so the
    \\destination can sample mixes the source never emits. Gray-code
    \\the source, handshake it, or sync the bus whole.
    ,
    .honors = &.{ "cdc_gray", "cdc_static", "cdc_handshake" },
    .check_all = checkAll,
};

// One finding per (source register, dst clock) group reaching
// two or more destinations. Bus records collapse into the same
// keys their lanes already hold, so whole buses never fire.
pub const Accum = struct {
    groups: std.AutoHashMapUnmanaged(usize, std.StringHashMapUnmanaged(Dsts)) = .empty,
};

pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var acc = Accum{};
    for (ctx.crossings) |x| try accumulate(&acc, ctx, x);
    return finish(&acc, ctx);
}

pub fn accumulate(acc: *Accum, ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!void {
    switch (x.kind) {
        .flop_flop_bit, .flop_flop_bus, .port_flop, .port_flop_untyped => {},
        else => return,
    }
    if (!std.mem.eql(u8, x.dst.port, "D")) return;
    const sc = x.src.cell orelse return;
    const dc = x.dst.cell orelse return;
    if (clock.cells.isLatch(ctx.mod.cells[sc].type)) return;
    if (clock.cells.isLatch(ctx.mod.cells[dc].type)) return;
    if (std.mem.eql(u8, x.dst_clk, "unknown")) return;
    if (std.mem.eql(u8, x.src_clk, x.dst_clk)) return;
    const sq = ctx.mod.cells[sc].portBits("Q") orelse return;
    if (sq.len < 2) return;
    const outer = try acc.groups.getOrPut(ctx.range_alloc, sc);
    if (!outer.found_existing) outer.value_ptr.* = .empty;
    const inner = try outer.value_ptr.getOrPut(ctx.range_alloc, x.dst_clk);
    if (!inner.found_existing) {
        inner.value_ptr.* = .empty;
        inner.key_ptr.* = try ctx.range_alloc.dupe(u8, x.dst_clk);
    }
    try inner.value_ptr.put(ctx.range_alloc, ctx.mod.cells[dc].name, dc);
}

pub fn finish(acc: *Accum, ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var keys = std.ArrayListUnmanaged(Key).empty;
    var oit = acc.groups.iterator();
    while (oit.next()) |oe| {
        var iit = oe.value_ptr.iterator();
        while (iit.next()) |ie| {
            if (ie.value_ptr.count() < 2) continue;
            try keys.append(ctx.tmp, .{ .src = oe.key_ptr.*, .clk = ie.key_ptr.*, .dsts = ie.value_ptr.* });
        }
    }
    std.mem.sort(Key, keys.items, ctx, struct {
        fn less(c: *context.Context, a: Key, b: Key) bool {
            const ak = std.mem.order(u8, c.mod.cells[a.src].name, c.mod.cells[b.src].name);
            if (ak != .eq) return ak == .lt;
            return std.mem.order(u8, a.clk, b.clk) == .lt;
        }
    }.less);
    for (keys.items) |k| {
        const src_name = ctx.mod.cells[k.src].name;
        if (ctx.marks.hasGray(src_name)) continue;
        if (ctx.marks.hasStatic(src_name)) continue;
        if (ctx.marks.hasHandshake(src_name)) continue;
        if (bus.isGrayEncodedSource(ctx, k.src)) {
            var gray_ok = false;
            var dit = k.dsts.iterator();
            while (dit.next()) |de| {
                if (bus.isMultibitSyncFirstStage(ctx, de.value_ptr.*, k.clk)) gray_ok = true;
            }
            if (gray_ok) continue;
        }
        var names = std.ArrayListUnmanaged([]const u8).empty;
        var dit = k.dsts.iterator();
        while (dit.next()) |de| try names.append(ctx.tmp, de.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        const sq = ctx.mod.cells[k.src].portBits("Q").?;
        const desc = try laneDesc(ctx, names.items);
        const message = try std.fmt.allocPrint(ctx.tmp, "sliced-bus reconvergence across CDC: source flop {s} (WIDTH={d}) is sliced into {d} per-lane crossings to clock domain {s} ({s}). Each lane resolves metastability on its own schedule. Fix: gray-code the source, use a req/ack handshake, or replace the per-lane sync chains with a single multi-bit sync chain.", .{ src_name, sq.len, names.items.len, desc, k.clk });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = src_name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

const Dsts = std.StringHashMapUnmanaged(usize);

const Key = struct {
    src: usize,
    clk: []const u8,
    dsts: Dsts,
};

// First four lanes, then a total: wide buses stay readable
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
