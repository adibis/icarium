// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-013",
    .severity = .warn,
    .title = "Toggle-synchronizer event loss on fast-to-slow crossing",
    .doc =
    \\A toggling source runs fast to slow past the period ratio:
    \\two toggles between destination samples cancel to zero edges
    \\and both events are silently lost. A handshake or
    \\backpressure closes it. An XOR tail does not: it turns each
    \\toggle into a pulse, but cancelled toggles never reach it.
    ,
    .honors = &.{"cdc_handshake"},
    .check = check,
};

// Toggle-D flop sources with declared periods past the 1.5x
// ratio. No async gate: the ratio alone decides, related or not.
pub fn check(ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!?finding.Finding {
    if (x.kind != .flop_flop_bit) return null;
    if (ctx.isBusMember(x)) return null;
    if (std.mem.eql(u8, x.src_clk, "unknown")) return null;
    const sc = x.src.cell orelse return null;
    const dc = x.dst.cell orelse return null;
    const src_clk = ctx.model.clocks.get(x.src_clk) orelse return null;
    const dst_clk = ctx.model.clocks.get(x.dst_clk) orelse return null;
    const sp = src_clk.period orelse return null;
    const dp = dst_clk.period orelse return null;
    if (!(sp * 1.5 < dp)) return null;
    const d = ctx.mod.cells[sc].portBits("D") orelse return null;
    const q = ctx.mod.cells[sc].portBits("Q") orelse return null;
    if (d.len != 1 or q.len != 1) return null;
    if (d[0] != .sig or q[0] != .sig) return null;
    if (ctx.marks.hasHandshake(ctx.mod.cells[sc].name)) return null;
    if (!isToggleD(ctx, d[0].sig, q[0].sig)) return null;
    const message = try std.fmt.allocPrint(ctx.tmp, "toggle-synchronizer event-loss risk on '{s}' -> '{s}': src clock '{s}' (period {d}) is faster than dst clock '{s}' (period {d}); the src flop toggles on an enable and two events between dst samples cancel to zero edges. Use a req/ack handshake or an event counter with backpressure.", .{ ctx.mod.cells[sc].name, ctx.mod.cells[dc].name, x.src_clk, sp, x.dst_clk, dp });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = ctx.mod.cells[sc].name,
        .message = message,
    };
}

const not_types = std.StaticStringMap(void).initComptime(.{
    .{ "$not", {} },
    .{ "$logic_not", {} },
    .{ "$_NOT_", {} },
});

// D is $mux Y with (Q, ~Q) data legs in either order: the
// `if (en) q <= ~q` shape after proc. The select is anything.
fn isToggleD(ctx: *context.Context, d_bit: u32, q_bit: u32) bool {
    const mod = ctx.mod;
    const drv = mod.driver_of.get(d_bit) orelse return false;
    const ci = drv.cell orelse return false;
    if (!std.mem.eql(u8, drv.port, "Y")) return false;
    const c = mod.cells[ci];
    if (!std.mem.eql(u8, c.type, "$mux")) return false;
    const a = c.portBits("A") orelse return false;
    const b = c.portBits("B") orelse return false;
    if (a.len != 1 or b.len != 1) return false;
    if (a[0] != .sig or b[0] != .sig) return false;
    const legs = [2][2]u32{ .{ a[0].sig, b[0].sig }, .{ b[0].sig, a[0].sig } };
    for (legs) |leg| {
        if (leg[0] != q_bit) continue;
        const ndrv = mod.driver_of.get(leg[1]) orelse continue;
        const nci = ndrv.cell orelse continue;
        if (!std.mem.eql(u8, ndrv.port, "Y")) continue;
        const n = mod.cells[nci];
        if (not_types.get(n.type) == null) continue;
        const na = n.portBits("A") orelse continue;
        if (na.len == 1 and na[0] == .sig and na[0].sig == q_bit) return true;
    }
    return false;
}
