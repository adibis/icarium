const std = @import("std");
const bus = @import("bus.zig");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-018",
    .severity = .warn,
    .title = "Cascaded synchronizer chain past the depth threshold",
    .doc =
    \\A destination chain runs deeper than the threshold (default
    \\4): two stacked 2FF syncs, or a refactor leftover. Extra
    \\stages add latency without improving resolution. Trim to 2,
    \\raise the threshold, or vouch the head.
    ,
    .honors = &.{"cdc_sync"},
    .check_all = checkAll,
};

// Deepest chain per (source, dst clock): at-threshold chains
// report once, naming the longest head. Vouched heads abstain.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var groups = std.AutoHashMapUnmanaged(usize, std.StringHashMapUnmanaged(Best)).empty;
    for (ctx.crossings) |x| {
        switch (x.kind) {
            .flop_flop_bit, .port_flop, .port_flop_untyped => {},
            else => continue,
        }
        if (!std.mem.eql(u8, x.dst.port, "D")) continue;
        const sc = x.src.cell orelse continue;
        const dc = x.dst.cell orelse continue;
        if (clock.cells.isLatch(ctx.mod.cells[dc].type)) continue;
        if (clock.cells.isLatch(ctx.mod.cells[sc].type)) continue;
        if (std.mem.eql(u8, x.dst_clk, "unknown")) continue;
        if (std.mem.eql(u8, x.src_clk, x.dst_clk)) continue;
        if (ctx.marks.hasSync(ctx.mod.cells[dc].name)) continue;
        const d = bus.portBits(ctx.mod.cells[dc], "D") orelse continue;
        const q = bus.portBits(ctx.mod.cells[dc], "Q") orelse continue;
        if (d.len != 1 or q.len != 1) continue;
        if (d[0] != .sig or q[0] != .sig) continue;
        const entry = try ctx.table.chainDepth(ctx.mod, dc, x.dst_clk);
        if (entry.depth < ctx.cfg.cdc018_threshold) continue;
        const outer = try groups.getOrPut(ctx.alloc, sc);
        if (!outer.found_existing) outer.value_ptr.* = .empty;
        const inner = try outer.value_ptr.getOrPut(ctx.alloc, x.dst_clk);
        if (!inner.found_existing or entry.depth > inner.value_ptr.depth) {
            inner.value_ptr.* = .{ .depth = entry.depth, .head = dc };
        }
    }
    var keys = std.ArrayListUnmanaged(Key).empty;
    var oit = groups.iterator();
    while (oit.next()) |oe| {
        var iit = oe.value_ptr.iterator();
        while (iit.next()) |ie| {
            try keys.append(ctx.alloc, .{ .src = oe.key_ptr.*, .clk = ie.key_ptr.*, .best = ie.value_ptr.* });
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
        const message = try std.fmt.allocPrint(ctx.alloc,
            "cascaded synchroniser chain: {d}-flop chain in {s} starting at {s} (source: {s}). The textbook 2FF sync is sufficient; every flop beyond the first 2 adds latency without improving metastability resolution. Trim the chain to 2 flops, or mark the chain head (* cdc_sync *) if the depth is intentional.",
            .{ k.best.depth, k.clk, ctx.mod.cells[k.best.head].name, ctx.mod.cells[k.src].name });
        try out.append(ctx.alloc, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = ctx.mod.cells[k.best.head].name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.alloc);
}

const Best = struct { depth: u32, head: usize };
const Key = struct { src: usize, clk: []const u8, best: Best };
