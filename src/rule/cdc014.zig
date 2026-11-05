const std = @import("std");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-014",
    .severity = .err,
    .title = "Combinational logic between synchronizer stages",
    .doc =
    \\A gate sits between two stages of a synchronizer: the second
    \\stage may sample the first while still metastable, destroying
    \\the resolution time the chain was meant to provide. Move the
    \\gate past the chain's final stage.
    ,
    .honors = &.{ "cdc_sync", "cdc_handshake" },
    .check = check,
};

// Single-bit flop destinations whose Q fans through a gate into
// a same-clock follow-on. Clock names must differ: the reference
// only ever sees records for distinct-domain pairs.
pub fn check(ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!?finding.Finding {
    switch (x.kind) {
        .flop_flop_bit, .port_flop, .port_flop_untyped => {},
        else => return null,
    }
    if (!std.mem.eql(u8, x.dst.port, "D")) return null;
    const dc = x.dst.cell orelse return null;
    if (std.mem.eql(u8, x.dst_clk, "unknown")) return null;
    if (std.mem.eql(u8, x.src_clk, x.dst_clk)) return null;
    const head_name = ctx.mod.cells[dc].name;
    if (ctx.marks.hasSync(head_name)) return null;
    if (ctx.marks.hasHandshake(head_name)) return null;
    const nxt = ctx.table.hasInterStageComb(ctx.mod, dc) orelse return null;
    const message = try std.fmt.allocPrint(ctx.alloc,
        "combinational logic between synchronizer stages on {s} -> {s}: head {s} feeds a comb cell whose output reaches {s} (same clock domain). The gate's propagation delay can sample a metastable head output. Remove the gate and place it after the chain's final stage.",
        .{ x.src_clk, x.dst_clk, head_name, ctx.mod.cells[nxt].name });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = head_name,
        .message = message,
    };
}
