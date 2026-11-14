// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
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
    \\A toggle whose enable waits on its own acknowledgement, the
    \\destination's synchronized toggle returned through a 2FF
    \\chain, never toggles twice between samples and is silent.
    ,
    .honors = &.{"cdc_handshake"},
    .check = check,
};

// Toggle-D flop sources with declared periods past the 1.5x
// ratio, unless the toggle waits on its own acknowledgement.
// No async gate: the ratio alone decides, related or not.
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
    const mux = toggleMux(ctx, d[0].sig, q[0].sig) orelse return null;
    if (try acknowledged(ctx, mux, sc, dc, x)) return null;
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
// `if (en) q <= ~q` shape after proc. Returns the mux, whose
// select is the toggle's enable.
fn toggleMux(ctx: *context.Context, d_bit: u32, q_bit: u32) ?usize {
    const mod = ctx.mod;
    const drv = mod.driver_of.get(d_bit) orelse return null;
    const ci = drv.cell orelse return null;
    if (!std.mem.eql(u8, drv.port, "Y")) return null;
    const c = mod.cells[ci];
    if (!std.mem.eql(u8, c.type, "$mux")) return null;
    const a = c.portBits("A") orelse return null;
    const b = c.portBits("B") orelse return null;
    if (a.len != 1 or b.len != 1) return null;
    if (a[0] != .sig or b[0] != .sig) return null;
    const legs = [2][2]u32{ .{ a[0].sig, b[0].sig }, .{ b[0].sig, a[0].sig } };
    for (legs) |leg| {
        if (leg[0] != q_bit) continue;
        const ndrv = mod.driver_of.get(leg[1]) orelse continue;
        const nci = ndrv.cell orelse continue;
        if (!std.mem.eql(u8, ndrv.port, "Y")) continue;
        const n = mod.cells[nci];
        if (not_types.get(n.type) == null) continue;
        const na = n.portBits("A") orelse continue;
        if (na.len == 1 and na[0] == .sig and na[0].sig == q_bit) return ci;
    }
    return null;
}

// The enable waits on an acknowledgement of this very crossing: a
// source-domain flop in the select cone ends a 2+ stage chain whose
// head samples a stage of the destination's own synchronizer. Any
// other ready signal proves nothing about this toggle.
fn acknowledged(ctx: *context.Context, mux: usize, sc: usize, dc: usize, x: crossing.enumerate.Crossing) error{OutOfMemory}!bool {
    const mod = ctx.mod;
    const sel = mod.cells[mux].portBits("S") orelse return false;
    const fwd = try ctx.table.chainDepth(mod, dc, x.dst_clk);
    const fanin = try context.backwardFlopFanin(ctx.tmp, mod, sel);
    for (fanin.items) |f| {
        if (f == sc) continue;
        if (!inDomain(ctx, f, x.src_clk)) continue;
        var cur = f;
        var stages: usize = 1;
        while (stages <= 8) {
            const prev = directFlopDriver(ctx, cur) orelse break;
            if (std.mem.indexOfScalar(usize, fwd.stages, prev) != null) {
                if (stages >= 2) return true;
                break;
            }
            if (!inDomain(ctx, prev, x.src_clk)) break;
            cur = prev;
            stages += 1;
        }
    }
    return false;
}

fn inDomain(ctx: *context.Context, ci: usize, clk: []const u8) bool {
    const dom = ctx.table.domainOf(ci) orelse return false;
    return std.mem.eql(u8, dom.name, clk);
}

// The flop whose Q alone drives this flop's D, with no logic between.
fn directFlopDriver(ctx: *context.Context, ci: usize) ?usize {
    const mod = ctx.mod;
    const d = mod.cells[ci].portBits("D") orelse return null;
    if (d.len != 1 or d[0] != .sig) return null;
    const drv = mod.driver_of.get(d[0].sig) orelse return null;
    const pc = drv.cell orelse return null;
    if (!std.mem.eql(u8, drv.port, "Q")) return null;
    const t = mod.cells[pc].type;
    if (!clock.cells.isSequential(t) or clock.cells.isLatch(t)) return null;
    return pc;
}
