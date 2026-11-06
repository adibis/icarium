const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");
const sync = @import("../sync.zig");

pub const rule = registry.Rule{
    .id = "CDC-002",
    .severity = .warn,
    .title = "Insufficient synchronizer depth",
    .doc =
    \\A synchronizer chain exists but is shorter than the site minimum
    \\(--sync-depth, default 2): raise the depth or lower the bar.
    \\Silent at the default unless a project explicitly requires more.
    ,
    .honors = &.{ "cdc_static", "cdc_sync" },
    .check = check,
};

// Same candidacy as CDC-001, firing only in the depth window
// the site minimum opens above a proven two stages.
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
    if (x.src.cell) |sc| {
        if (ctx.marks.hasStatic(ctx.mod.cells[sc].name)) return null;
        if (sync.primitives.isSyncPrimitive(ctx.mod.cells[sc].type, ctx.cfg.sync_primitives)) return null;
    }
    const depth = try ctx.table.chainDepth(ctx.mod, dc, x.dst_clk);
    if (depth.depth < 2 or depth.depth >= ctx.cfg.sync_depth) return null;
    const message = try std.fmt.allocPrint(ctx.tmp,
        "insufficient synchronizer depth on {s} -> {s} crossing: found {d} flop(s), required >= {d} (dst flop: {s})",
        .{ x.src_clk, x.dst_clk, depth.depth, ctx.cfg.sync_depth, dst_name });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = dst_name,
        .message = message,
    };
}
