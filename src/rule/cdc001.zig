const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-001",
    .severity = .err,
    .title = "Unsynchronized control crossing",
    .doc =
    \\The destination flop has no follow-on synchronizer in its own
    \\clock: a single-bit signal lands and is used directly, with no
    \\second stage to filter metastability. Add a 2FF chain, or assert
    \\(* cdc_sync *) on a vetted synchronizer, (* cdc_static *) on a
    \\source held constant, (* cdc_handshake *) on a capture register.
    ,
    .honors = &.{ "cdc_static", "cdc_sync", "cdc_handshake" },
    .check = check,
};

// Single-bit async pairs into flop D, unless a user mark vouches
// or a gate sits between the stages (that shape is CDC-014's).
pub fn check(ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!?finding.Finding {
    if (!x.async_per_sdc) return null;
    const single = x.kind == .flop_flop_bit or x.kind == .port_flop;
    if (!single) return null;
    if (ctx.isBusMember(x)) return null;
    if (!std.mem.eql(u8, x.dst.port, "D")) return null;
    const dc = x.dst.cell orelse return null;
    const dt = ctx.mod.cells[dc].type;
    if (!clock.cells.isSequential(dt) or clock.cells.isLatch(dt)) return null;
    const dst_name = ctx.mod.cells[dc].name;
    if (ctx.marks.hasSync(dst_name)) return null;
    if (ctx.marks.hasHandshake(dst_name)) return null;
    if (x.src.cell) |sc| {
        if (ctx.marks.hasStatic(ctx.mod.cells[sc].name)) return null;
    }
    const depth = try ctx.table.chainDepth(ctx.mod, dc, x.dst_clk);
    if (depth.depth >= 2) return null;
    if (ctx.table.hasInterStageComb(ctx.mod, dc) != null) return null;
    const src_desc = if (x.src.cell) |sc|
        try std.fmt.allocPrint(ctx.alloc, "flop {s}", .{ctx.mod.cells[sc].name})
    else
        try std.fmt.allocPrint(ctx.alloc, "port {s}", .{x.src.port});
    const message = try std.fmt.allocPrint(ctx.alloc,
        "unsynchronized control crossing {s} -> {s} (src: {s}): destination flop {s} has no second-stage synchronizer (chain depth = {d})",
        .{ x.src_clk, x.dst_clk, src_desc, dst_name, depth.depth });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = dst_name,
        .message = message,
    };
}
