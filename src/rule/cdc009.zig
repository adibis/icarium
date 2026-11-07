const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-009",
    .severity = .warn,
    .title = "Pulse-width risk on fast-to-slow data crossings",
    .doc =
    \\A single-bit flop crossing runs fast to slow (source period
    \\times 1.5 below the destination period) and the source flop
    \\is an edge detector: a 1-cycle pulse may slip between slow
    \\edges. Stretch the pulse, toggle it, or handshake it.
    ,
    .honors = &.{},
    .check = check,
};

// Flop pairs with declared periods and an edge-detector source.
// No async gate: the ratio alone decides, related or not.
pub fn check(ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!?finding.Finding {
    if (x.kind != .flop_flop_bit) return null;
    if (ctx.isBusMember(x)) return null;
    const sc = x.src.cell orelse return null;
    const dc = x.dst.cell orelse return null;
    const src_clk = ctx.model.clocks.get(x.src_clk) orelse return null;
    const dst_clk = ctx.model.clocks.get(x.dst_clk) orelse return null;
    const sp = src_clk.period orelse return null;
    const dp = dst_clk.period orelse return null;
    if (!(sp * 1.5 < dp)) return null;
    const d = ctx.mod.cells[sc].portBits("D") orelse return null;
    if (d.len != 1 or d[0] != .sig) return null;
    if (!isEdgeDetector(ctx, d[0].sig, x.src_clk)) return null;
    const message = try std.fmt.allocPrint(ctx.tmp, "pulse-width risk on '{s}' -> '{s}': src clock '{s}' (period {d}) is faster than dst clock '{s}' (period {d}); a 1-cycle src pulse may not be captured. Consider a pulse-stretcher, toggle synchronizer, or req/ack handshake.", .{ ctx.mod.cells[sc].name, ctx.mod.cells[dc].name, x.src_clk, sp, x.dst_clk, dp });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = ctx.mod.cells[sc].name,
        .message = message,
    };
}

const and_types = std.StaticStringMap(void).initComptime(.{
    .{ "$and", {} },
    .{ "$logic_and", {} },
    .{ "$_AND_", {} },
});

const not_types = std.StaticStringMap(void).initComptime(.{
    .{ "$not", {} },
    .{ "$logic_not", {} },
    .{ "$_NOT_", {} },
});

// D is A & ~A_d: one AND leg a same-clock flop Q, the other the
// inverted Q of that flop's 1-cycle delay. Either order counts.
fn isEdgeDetector(ctx: *context.Context, d_bit: u32, src_clock: []const u8) bool {
    const drv = ctx.mod.driver_of.get(d_bit) orelse return false;
    const ci = drv.cell orelse return false;
    const c = ctx.mod.cells[ci];
    if (and_types.get(c.type) == null or !std.mem.eql(u8, drv.port, "Y")) return false;
    const a = c.portBits("A") orelse return false;
    const b = c.portBits("B") orelse return false;
    if (a.len != 1 or b.len != 1) return false;
    if (a[0] != .sig or b[0] != .sig) return false;
    return isPair(ctx, a[0].sig, b[0].sig, src_clock) or
        isPair(ctx, b[0].sig, a[0].sig, src_clock);
}

fn isPair(ctx: *context.Context, direct: u32, inverted: u32, src_clock: []const u8) bool {
    if (srcFlopDPin(ctx, direct, src_clock) == null) return false;
    const drv = ctx.mod.driver_of.get(inverted) orelse return false;
    const ci = drv.cell orelse return false;
    const c = ctx.mod.cells[ci];
    if (not_types.get(c.type) == null or !std.mem.eql(u8, drv.port, "Y")) return false;
    const na = c.portBits("A") orelse return false;
    if (na.len != 1 or na[0] != .sig) return false;
    const delay_d = srcFlopDPin(ctx, na[0].sig, src_clock) orelse return false;
    return delay_d == direct;
}

// Q of a single-bit flop in the source domain, answered with
// its D bit. Anything else is not an edge-detector operand.
fn srcFlopDPin(ctx: *context.Context, q_bit: u32, src_clock: []const u8) ?u32 {
    const drv = ctx.mod.driver_of.get(q_bit) orelse return null;
    const ci = drv.cell orelse return null;
    if (!std.mem.eql(u8, drv.port, "Q")) return null;
    const c = ctx.mod.cells[ci];
    if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) return null;
    const dom = ctx.table.domainOf(ci) orelse return null;
    if (!std.mem.eql(u8, dom.name, src_clock)) return null;
    const d = c.portBits("D") orelse return null;
    const q = c.portBits("Q") orelse return null;
    if (d.len != 1 or q.len != 1 or d[0] != .sig) return null;
    return d[0].sig;
}
