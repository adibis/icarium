// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-015",
    .severity = .err,
    .title = "Synchronizer chain released by a foreign-domain reset",
    .doc =
    \\A synchronizer chain takes its async reset from another clock
    \\domain: every foreign deassertion races the chain clock, so the
    \\resolving flops never reach steady state. Reset the chain from
    \\its own domain, or synchronize the reset into it.
    ,
    .honors = &.{"cdc_sync"},
    .check_all = checkAll,
};

// One finding per chain head: any stage whose ARST fanin reaches
// a flop async to the chain clock. Fires beside RDC-001 by
// design; each frames a different fix for the shared shape.
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
        const offenders = try foreignResets(ctx, entry.stages, x.dst_clk);
        if (offenders.len == 0) continue;
        try seen.put(ctx.tmp, dc, {});
        std.mem.sort(Offender, offenders, {}, struct {
            fn less(_: void, a: Offender, b: Offender) bool {
                const ck = std.mem.order(u8, a.name, b.name);
                if (ck != .eq) return ck == .lt;
                return std.mem.order(u8, a.clk, b.clk) == .lt;
            }
        }.less);
        var names = std.ArrayListUnmanaged(u8).empty;
        for (offenders, 0..) |o, i| {
            if (i > 0) try names.appendSlice(ctx.tmp, ", ");
            const one = try std.fmt.allocPrint(ctx.tmp, "{s} ({s})", .{ o.name, o.clk });
            try names.appendSlice(ctx.tmp, one);
        }
        const message = try std.fmt.allocPrint(ctx.tmp, "synchronizer chain in {s} (head {s}) has ARST driven by foreign-domain source(s): {s}. The chain cannot reach steady state because its resolving flops are asynchronously released by a reset that is not in {s}'s reset tree. Use {s}'s reset (or a reset synchronised into {s}) for the sync chain.", .{ x.dst_clk, ctx.mod.cells[dc].name, names.items, x.dst_clk, x.dst_clk, x.dst_clk });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = ctx.mod.cells[dc].name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

const Offender = struct { name: []const u8, clk: []const u8 };

// Every flop in any stage's ARST fanin that sits in a known
// clock async to the chain clock. Unknown clocks abstain:
// absence of attribution is not evidence of foreignness.
fn foreignResets(
    ctx: *context.Context,
    stages: []usize,
    dst_clock: []const u8,
) error{OutOfMemory}![]Offender {
    var out = std.ArrayListUnmanaged(Offender).empty;
    var seen = std.AutoHashMapUnmanaged(usize, void).empty;
    for (stages) |s| {
        const arst = ctx.mod.cells[s].portBits("ARST") orelse continue;
        if (arst.len == 0) continue;
        const fanin = try context.backwardFlopFanin(ctx.tmp, ctx.mod, arst);
        for (fanin.items) |f| {
            if (seen.contains(f)) continue;
            try seen.put(ctx.tmp, f, {});
            const dom = ctx.table.domainOf(f) orelse continue;
            if (std.mem.eql(u8, dom.name, "unknown")) continue;
            if (std.mem.eql(u8, dom.name, dst_clock)) continue;
            if (!ctx.model.areAsync(dom.name, dst_clock)) continue;
            try out.append(ctx.tmp, .{ .name = ctx.mod.cells[f].name, .clk = dom.name });
        }
    }
    return out.toOwnedSlice(ctx.tmp);
}
