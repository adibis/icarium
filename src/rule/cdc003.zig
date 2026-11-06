const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-003",
    .severity = .err,
    .title = "Combinational logic on the way to a synchronizer",
    .doc =
    \\Source-domain signals combine through a gate before the
    \\synchronizer: the gate can glitch across source cycles and a
    \\2FF cannot filter the transient. Synchronize each source bit
    \\first, then combine in the destination domain.
    ,
    .honors = &.{ "cdc_static", "cdc_sync" },
    .check = check,
};

// Flop-sourced pairs with cells on the path into a proven
// chain. Ports, depth-1 pairs, and lone reset muxes defer out.
pub fn check(ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!?finding.Finding {
    if (!x.async_per_sdc) return null;
    if (x.kind != .flop_flop_bit) return null;
    if (ctx.isBusMember(x)) return null;
    if (x.hop_count < 1) return null;
    if (!std.mem.eql(u8, x.dst.port, "D")) return null;
    const dc = x.dst.cell orelse return null;
    const sc = x.src.cell orelse return null;
    const dt = ctx.mod.cells[dc].type;
    if (!clock.cells.isSequential(dt) or clock.cells.isLatch(dt)) return null;
    const dst_name = ctx.mod.cells[dc].name;
    if (ctx.marks.hasSync(dst_name)) return null;
    if (ctx.marks.hasStatic(ctx.mod.cells[sc].name)) return null;
    if (x.hop_count == 1 and ctx.table.resetMuxEntry(ctx.mod, dc, x.src.bit)) return null;
    const depth = try ctx.table.chainDepth(ctx.mod, dc, x.dst_clk);
    if (depth.depth < 2) return null;
    const message = try std.fmt.allocPrint(ctx.alloc,
        "combinational logic between source flop and synchronizer on {s} -> {s} crossing: {d} cell(s) on path (src: {s}, sync first stage: {s})",
        .{ x.src_clk, x.dst_clk, x.hop_count, ctx.mod.cells[sc].name, dst_name });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = dst_name,
        .message = message,
    };
}
