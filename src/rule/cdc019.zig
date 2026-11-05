const std = @import("std");
const bus = @import("bus.zig");
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
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var groups = std.AutoHashMapUnmanaged(usize, std.StringHashMapUnmanaged(Group)).empty;
    for (ctx.report.crossings) |x| {
        switch (x.kind) {
            .flop_flop_bit, .port_flop, .port_flop_untyped => {},
            else => continue,
        }
        if (!std.mem.eql(u8, x.dst.port, "D")) continue;
        const sc = x.src.cell orelse continue;
        const dc = x.dst.cell orelse continue;
        if (clock.cells.isLatch(ctx.mod.cells[sc].type)) continue;
        if (clock.cells.isLatch(ctx.mod.cells[dc].type)) continue;
        if (std.mem.eql(u8, x.dst_clk, "unknown")) continue;
        if (std.mem.eql(u8, x.src_clk, x.dst_clk)) continue;
        const sd = bus.portBits(ctx.mod.cells[sc], "D") orelse continue;
        if (sd.len != 1 or sd[0] != .sig) continue;
        const drv = ctx.mod.driver_of.get(sd[0].sig) orelse continue;
        const di = drv.cell orelse continue;
        if (!std.mem.eql(u8, drv.port, "Y")) continue;
        const dt = ctx.mod.cells[di].type;
        if (clock.cells.isSequential(dt) and !clock.cells.isLatch(dt)) continue;
        const y = bus.portBits(ctx.mod.cells[di], "Y") orelse continue;
        var wide = false;
        var int_bits: usize = 0;
        for (y) |b| {
            if (b == .sig) int_bits += 1;
        }
        if (int_bits >= 2) wide = true;
        if (!wide) continue;
        const outer = try groups.getOrPut(ctx.alloc, di);
        if (!outer.found_existing) outer.value_ptr.* = .empty;
        const inner = try outer.value_ptr.getOrPut(ctx.alloc, x.dst_clk);
        if (!inner.found_existing) inner.value_ptr.* = .{ .lanes = .empty, .suppressed = false };
        const src_name = ctx.mod.cells[sc].name;
        if (ctx.marks.hasGray(src_name) or
            ctx.marks.hasStatic(src_name) or
            ctx.marks.hasSync(src_name))
        {
            inner.value_ptr.suppressed = true;
            continue;
        }
        try inner.value_ptr.lanes.put(ctx.alloc, src_name, ctx.mod.cells[dc].name);
    }
    var keys = std.ArrayListUnmanaged(Key).empty;
    var oit = groups.iterator();
    while (oit.next()) |oe| {
        var iit = oe.value_ptr.iterator();
        while (iit.next()) |ie| {
            if (ie.value_ptr.suppressed) continue;
            if (ie.value_ptr.lanes.count() < 2) continue;
            try keys.append(ctx.alloc, .{ .drv = oe.key_ptr.*, .clk = ie.key_ptr.*, .lanes = ie.value_ptr.lanes });
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
        while (lit.next()) |le| try names.append(ctx.alloc, le.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        const desc = try laneDesc(ctx, names.items);
        const message = try std.fmt.allocPrint(ctx.alloc,
            "independently-synced one-hot decode across CDC: comb cell {s} drives {d} separate WIDTH=1 source flops ({s}) that each cross independently to clock domain {s}. The shared decoder makes the lanes change together at the source, but each destination sync chain resolves on its own schedule. Fix: gray-code the source or gate the destination sample behind a req/ack handshake.",
            .{ ctx.mod.cells[k.drv].name, names.items.len, desc, k.clk });
        try out.append(ctx.alloc, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = names.items[0],
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.alloc);
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
        if (i > 0) try buf.appendSlice(ctx.alloc, ", ");
        try buf.appendSlice(ctx.alloc, n);
    }
    if (names.len > 4) {
        const tail = try std.fmt.allocPrint(ctx.alloc, ", ... ({d} lanes total)", .{names.len});
        try buf.appendSlice(ctx.alloc, tail);
    }
    return buf.toOwnedSlice(ctx.alloc);
}
