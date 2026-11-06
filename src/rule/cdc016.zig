const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-016",
    .severity = .err,
    .title = "Opposite-edge stages in a synchronizer chain",
    .doc =
    \\Adjacent chain stages sample on opposite edges of one clock,
    \\halving the resolution time a same-edge chain would provide.
    \\The RTL reads as a symmetric 2FF, but MTBF roughly halves.
    \\Sample every stage on the same edge.
    ,
    .honors = &.{"cdc_sync"},
    .check_all = checkAll,
};

// One finding per chain head: the first adjacent stage pair
// whose clock polarities disagree. Depth checks pass these
// chains, so the polarity walk is the only witness.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var seen = std.AutoHashMapUnmanaged(usize, void).empty;
    for (ctx.crossings) |x| {
        switch (x.kind) {
            .flop_flop_bit, .port_flop, .port_flop_untyped => {},
            else => continue,
        }
        if (ctx.isBusMember(x)) continue;
        if (!std.mem.eql(u8, x.dst.port, "D")) continue;
        const dc = x.dst.cell orelse continue;
        if (clock.cells.isLatch(ctx.mod.cells[dc].type)) continue;
        if (std.mem.eql(u8, x.dst_clk, "unknown")) continue;
        if (std.mem.eql(u8, x.src_clk, x.dst_clk)) continue;
        if (seen.contains(dc)) continue;
        if (ctx.marks.hasSync(ctx.mod.cells[dc].name)) continue;
        const entry = try ctx.table.chainDepth(ctx.mod, dc, x.dst_clk);
        if (entry.stages.len < 2) continue;
        for (0..entry.stages.len - 1) |i| {
            const a = entry.stages[i];
            const b = entry.stages[i + 1];
            if (isPosedge(ctx.mod.cells[a]) == isPosedge(ctx.mod.cells[b])) continue;
            try seen.put(ctx.alloc, dc, {});
            const message = try std.fmt.allocPrint(ctx.alloc,
                "opposite-edge synchroniser on {s} -> {s}: chain stage {s} ({s}) and {s} ({s}) sample on different edges of {s}, which halves MTBF",
                .{ x.src_clk, x.dst_clk, ctx.mod.cells[a].name, edgeName(ctx.mod.cells[a]), ctx.mod.cells[b].name, edgeName(ctx.mod.cells[b]), x.dst_clk });
            try out.append(ctx.alloc, .{
                .rule = rule.id,
                .severity = rule.severity,
                .dst = ctx.mod.cells[dc].name,
                .message = message,
            });
            break;
        }
    }
    return out.toOwnedSlice(ctx.alloc);
}

fn edgeName(c: ir.types.Cell) []const u8 {
    return if (isPosedge(c)) "posedge" else "negedge";
}

// CLK_POLARITY says it outright; without the parameter the
// gate-level P/N segment decides; unknown cells read posedge,
// keeping the rule false-negative-biased, never noisy.
fn isPosedge(c: ir.types.Cell) bool {
    for (c.params) |p| {
        if (!std.mem.eql(u8, p.name, "CLK_POLARITY")) continue;
        return switch (p.value) {
            .str => |s| std.mem.eql(u8, s, "1"),
            .int => |i| i == 1,
        };
    }
    var segs = std.mem.splitScalar(u8, c.type, '_');
    while (segs.next()) |s| {
        if (std.mem.eql(u8, s, "P")) return true;
        if (std.mem.eql(u8, s, "N")) return false;
    }
    return true;
}
