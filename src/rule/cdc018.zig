// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-018",
    .severity = .warn,
    .title = "Synchronizer chain at or past the depth policy threshold",
    .doc =
    \\A destination chain whose depth is at least the configured
    \\threshold warns: depth >= threshold, default 4, so a 3-deep
    \\chain is quiet and 4- and 5-deep chains warn. It reports once
    \\per source and destination clock, on the head of the longest
    \\chain; a head marked cdc_sync abstains. This is a latency and
    \\area policy, not a safety defect: every stage adds latency and
    \\a flop, and also resolution time, which fast clocks or high
    \\data rates can need. Stacked 2FF syncs and refactor leftovers
    \\are the usual causes. Trim the chain, set the threshold your
    \\library needs, or vouch the head.
    ,
    .honors = &.{"cdc_sync"},
    .check_all = checkAll,
};

// Deepest chain per (source, dst clock): chains at or past the
// threshold report once, naming the longest head. Vouched heads abstain.
pub const Accum = struct {
    groups: std.AutoHashMapUnmanaged(usize, std.StringHashMapUnmanaged(Best)) = .empty,
};

pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var acc = Accum{};
    for (ctx.crossings) |x| try accumulate(&acc, ctx, x);
    return finish(&acc, ctx);
}

pub fn accumulate(acc: *Accum, ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!void {
    switch (x.kind) {
        .flop_flop_bit, .port_flop, .port_flop_untyped => {},
        else => return,
    }
    if (!std.mem.eql(u8, x.dst.port, "D")) return;
    const sc = x.src.cell orelse return;
    const dc = x.dst.cell orelse return;
    if (clock.cells.isLatch(ctx.mod.cells[dc].type)) return;
    if (clock.cells.isLatch(ctx.mod.cells[sc].type)) return;
    if (std.mem.eql(u8, x.dst_clk, "unknown")) return;
    if (std.mem.eql(u8, x.src_clk, x.dst_clk)) return;
    if (ctx.marks.hasSync(ctx.mod.cells[dc].name)) return;
    const d = ctx.mod.cells[dc].portBits("D") orelse return;
    const q = ctx.mod.cells[dc].portBits("Q") orelse return;
    if (d.len != 1 or q.len != 1) return;
    if (d[0] != .sig or q[0] != .sig) return;
    const entry = try ctx.table.chainDepth(ctx.mod, dc, x.dst_clk);
    if (entry.depth < ctx.cfg.cdc018_threshold) return;
    const outer = try acc.groups.getOrPut(ctx.alloc, sc);
    if (!outer.found_existing) outer.value_ptr.* = .empty;
    const inner = try outer.value_ptr.getOrPut(ctx.alloc, x.dst_clk);
    if (!inner.found_existing) {
        inner.value_ptr.* = .{ .depth = entry.depth, .head = dc };
        inner.key_ptr.* = try ctx.alloc.dupe(u8, x.dst_clk);
        return;
    }
    // Smaller head wins ties: first-seen would print different
    // heads per arrival order, but minima are order-free.
    const best = inner.value_ptr;
    if (entry.depth > best.depth or
        (entry.depth == best.depth and std.mem.lessThan(u8, ctx.mod.cells[dc].name, ctx.mod.cells[best.head].name)))
    {
        best.* = .{ .depth = entry.depth, .head = dc };
    }
}

pub fn finish(acc: *Accum, ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var keys = std.ArrayListUnmanaged(Key).empty;
    var oit = acc.groups.iterator();
    while (oit.next()) |oe| {
        var iit = oe.value_ptr.iterator();
        while (iit.next()) |ie| {
            try keys.append(ctx.tmp, .{ .src = oe.key_ptr.*, .clk = ie.key_ptr.*, .best = ie.value_ptr.* });
        }
    }
    std.mem.sort(Key, keys.items, ctx, struct {
        fn less(c: *context.Context, a: Key, b: Key) bool {
            const ak = std.mem.order(u8, c.mod.cells[a.src].name, c.mod.cells[b.src].name);
            if (ak != .eq) return ak == .lt;
            return std.mem.order(u8, a.clk, b.clk) == .lt;
        }
    }.less);
    for (keys.items) |k| {
        const message = try std.fmt.allocPrint(ctx.tmp, "cascaded synchroniser chain: {d}-flop chain in {s} starting at {s} (source: {s}). It is at or past the policy threshold of {d}; each stage adds latency and a flop as well as resolution time, and whether that resolution is needed depends on the library and clock rate. Trim the chain, set --cdc-018-depth-threshold to the depth your library needs, or mark the chain head (* cdc_sync *) if the depth is intentional.", .{ k.best.depth, k.clk, ctx.mod.cells[k.best.head].name, ctx.mod.cells[k.src].name, ctx.cfg.cdc018_threshold });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = ctx.mod.cells[k.best.head].name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

const Best = struct { depth: u32, head: usize };
const Key = struct { src: usize, clk: []const u8, best: Best };
