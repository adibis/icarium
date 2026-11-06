const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-024",
    .severity = .warn,
    .title = "Single source fanning to multiple synchronizers",
    .doc =
    \\One source bit reaches two or more synchronizer chains: each
    \\chain resolves metastability on its own edge, so the set only
    \\holds when the destinations never recombine what they latched
    \\apart. CDC-005 proves the recombination; this rule flags the
    \\fanout itself for the independence judgement.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// Candidates mirror CDC-005; they group by source bit alone, since
// fanout across different domains still resolves independently.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var cands = std.ArrayListUnmanaged(crossing.enumerate.Crossing).empty;
    for (ctx.crossings) |c| {
        if (try isCandidate(ctx, c)) try cands.append(ctx.alloc, c);
    }
    std.mem.sort(crossing.enumerate.Crossing, cands.items, ctx, struct {
        fn less(cx: *context.Context, a: crossing.enumerate.Crossing, b: crossing.enumerate.Crossing) bool {
            if (a.src.cell.? != b.src.cell.?) return a.src.cell.? < b.src.cell.?;
            if (a.src.bit != b.src.bit) return a.src.bit < b.src.bit;
            const ck = std.mem.order(u8, a.dst_clk, b.dst_clk);
            if (ck != .eq) return ck == .lt;
            return std.mem.lessThan(u8, cx.mod.cells[a.dst.cell.?].name, cx.mod.cells[b.dst.cell.?].name);
        }
    }.less);
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var i: usize = 0;
    while (i < cands.items.len) {
        var j = i + 1;
        while (j < cands.items.len and
            cands.items[j].src.cell.? == cands.items[i].src.cell.? and
            cands.items[j].src.bit == cands.items[i].src.bit) : (j += 1)
        {}
        const group = cands.items[i..j];
        if (try distinctDsts(ctx, group) >= 2) {
            try out.append(ctx.alloc, try fire(ctx, group));
        }
        i = j;
    }
    return out.toOwnedSlice(ctx.alloc);
}

fn isCandidate(ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!bool {
    if (registry.unknownSide(x)) return false;
    if (!x.async_per_sdc) return false;
    if (x.kind != .flop_flop_bit) return false;
    if (ctx.isBusMember(x)) return false;
    if (!std.mem.eql(u8, x.dst.port, "D")) return false;
    const dc = x.dst.cell orelse return false;
    if (x.src.cell == null) return false;
    const dt = ctx.mod.cells[dc].type;
    if (!clock.cells.isSequential(dt) or clock.cells.isLatch(dt)) return false;
    const depth = try ctx.table.chainDepth(ctx.mod, dc, x.dst_clk);
    return depth.depth >= 2;
}

// Distinct chain heads: two lanes into one flop are one sync.
fn distinctDsts(ctx: *context.Context, group: []crossing.enumerate.Crossing) error{OutOfMemory}!usize {
    var seen = std.AutoHashMapUnmanaged(usize, void).empty;
    for (group) |c| try seen.put(ctx.alloc, c.dst.cell.?, {});
    return seen.count();
}

fn fire(ctx: *context.Context, group: []crossing.enumerate.Crossing) error{OutOfMemory}!finding.Finding {
    const sc = group[0].src.cell.?;
    var names = std.ArrayListUnmanaged([]const u8).empty;
    var clocks = std.ArrayListUnmanaged([]const u8).empty;
    var seen_dst = std.AutoHashMapUnmanaged(usize, void).empty;
    var seen_clk = std.StringHashMapUnmanaged(void).empty;
    for (group) |c| {
        const dc = c.dst.cell.?;
        const ds = try seen_dst.getOrPut(ctx.alloc, dc);
        if (!ds.found_existing) try names.append(ctx.alloc, ctx.mod.cells[dc].name);
        const cs = try seen_clk.getOrPut(ctx.alloc, c.dst_clk);
        if (!cs.found_existing) try clocks.append(ctx.alloc, c.dst_clk);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    std.mem.sort([]const u8, clocks.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    const joined_names = try std.mem.join(ctx.alloc, ", ", names.items);
    const joined_clks = try std.mem.join(ctx.alloc, ", ", clocks.items);
    const message = try std.fmt.allocPrint(ctx.alloc,
        "fanout to {d} synchronizers: source {s} reaches independent sync chains in domain{s} {s} (chain heads: {s}); each chain resolves metastability on its own edge, so confirm the destinations never recombine the separately-resolved values",
        .{ names.items.len, ctx.mod.cells[sc].name, if (clocks.items.len == 1) "" else "s", joined_clks, joined_names });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = ctx.mod.cells[sc].name,
        .message = message,
    };
}
