const std = @import("std");
const bus = @import("bus.zig");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-004",
    .severity = .err,
    .title = "Multi-bit bus crossing without gating or gray-coding",
    .doc =
    \\A multi-bit path crosses domains with no coherence mechanism:
    \\lanes settle on different cycles, so the destination can sample
    \\a value never sent. Gate the bus behind a synchronized enable,
    \\gray-code it into a multi-bit chain, or assert the promise.
    ,
    .honors = &.{ "cdc_gray", "cdc_static" },
    .check = check,
};

// Bus records only: each must show gating, structural gray, or
// a user promise. Port buses clear by gating alone.
pub fn check(ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!?finding.Finding {
    if (x.kind != .flop_flop_bus and x.kind != .port_flop_bus) return null;
    if (!x.async_per_sdc) return null;
    const dc = x.dst.cell orelse return null;
    if (x.src.cell) |sc| {
        const src_name = ctx.mod.cells[sc].name;
        if (ctx.marks.hasGray(src_name)) return null;
        if (ctx.marks.hasStatic(src_name)) return null;
        if (isMultibitSyncFirstStage(ctx, dc, x.dst_clk) and
            bus.isGrayEncodedSource(ctx, sc)) return null;
    }
    if (try bus.isGatedBusCrossing(ctx, dc, x.dst_clk)) return null;
    const width = x.lanes.len;
    const src_desc = if (x.src.cell) |sc|
        try std.fmt.allocPrint(ctx.alloc, "flop {s}", .{ctx.mod.cells[sc].name})
    else
        try std.fmt.allocPrint(ctx.alloc, "port {s}", .{x.src.port});
    const message = try std.fmt.allocPrint(ctx.alloc,
        "unprotected bus crossing on {s} -> {s}: {d}-bit path with no recognized gating or gray-coding (src: {s}, dst flop: {s})",
        .{ x.src_clk, x.dst_clk, width, src_desc, ctx.mod.cells[dc].name });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = ctx.mod.cells[dc].name,
        .message = message,
    };
}

// Destination Q drives another same-width D lane for lane in the
// same clock: the async-FIFO pointer shape, gray-friendly.
fn isMultibitSyncFirstStage(ctx: *context.Context, dst: usize, dst_clock: []const u8) bool {
    const mod = ctx.mod;
    const c = mod.cells[dst];
    const q = bus.portBits(c, "Q") orelse return false;
    const d = bus.portBits(c, "D") orelse return false;
    if (q.len < 2 or d.len != q.len) return false;
    for (q) |qb| {
        if (qb != .sig) return false;
    }
    const loads = mod.loads_of.get(q[0].sig) orelse return false;
    for (loads.items) |loc| {
        const nci = loc.cell orelse continue;
        if (nci == dst) continue;
        if (!std.mem.eql(u8, loc.port, "D")) continue;
        const n = mod.cells[nci];
        if (!clock.cells.isSequential(n.type)) continue;
        const nd = bus.portBits(n, "D") orelse continue;
        if (nd.len != q.len) continue;
        var aligned = true;
        for (nd, q) |db, qb| {
            if (db != .sig or db.sig != qb.sig) aligned = false;
        }
        if (!aligned) continue;
        const dom = ctx.table.domainOf(nci) orelse continue;
        if (std.mem.eql(u8, dom.name, dst_clock)) return true;
    }
    return false;
}

