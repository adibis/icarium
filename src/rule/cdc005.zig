const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-005",
    .severity = .warn,
    .title = "Reconvergent synchronizers",
    .doc =
    \\One source flop fans out to independent synchronizer chains
    \\whose outputs recombine downstream: each chain resolves
    \\metastability on its own cycle, so the recombination can see
    \\a value pair never true at the source. Synchronize once and
    \\fan out after, or prove the skew harmless.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// Candidates gather by (source, clock); each group of two or
// more is tested for downstream recombination.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var cands = std.ArrayListUnmanaged(crossing.enumerate.Crossing).empty;
    for (ctx.report.crossings) |c| {
        if (try isCandidate(ctx, c)) try cands.append(ctx.alloc, c);
    }
    std.mem.sort(crossing.enumerate.Crossing, cands.items, ctx, struct {
        fn less(cx: *context.Context, a: crossing.enumerate.Crossing, b: crossing.enumerate.Crossing) bool {
            if (a.src.cell.? != b.src.cell.?) return a.src.cell.? < b.src.cell.?;
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
            std.mem.eql(u8, cands.items[j].dst_clk, cands.items[i].dst_clk)) : (j += 1)
        {}
        if (j - i >= 2 and try reconverges(ctx, cands.items[i..j])) {
            try out.append(ctx.alloc, try fire(ctx, cands.items[i..j]));
        }
        i = j;
    }
    return out.toOwnedSlice(ctx.alloc);
}

fn fire(ctx: *context.Context, group: []crossing.enumerate.Crossing) error{OutOfMemory}!finding.Finding {
    const sc = group[0].src.cell.?;
    var names = std.ArrayListUnmanaged([]const u8).empty;
    for (group) |c| {
        try names.append(ctx.alloc, ctx.mod.cells[c.dst.cell.?].name);
    }
    const joined = try std.mem.join(ctx.alloc, ", ", names.items);
    const message = try std.fmt.allocPrint(ctx.alloc,
        "reconvergent synchronizers: source flop {s} drives {d} independent sync chains in domain {s} (dst flops: {s}); independent metastability resolution can produce mismatched synchronized values when these outputs recombine",
        .{ ctx.mod.cells[sc].name, group.len, group[0].dst_clk, joined });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = ctx.mod.cells[sc].name,
        .message = message,
    };
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

// A cell reached from two chain terminals outside their own chains
// is a recombination point. Cones stop twelve hops out.
fn reconverges(ctx: *context.Context, group: []crossing.enumerate.Crossing) error{OutOfMemory}!bool {
    var counts = std.AutoHashMapUnmanaged(usize, u32).empty;
    for (group) |c| {
        const dc = c.dst.cell.?;
        const entry = try ctx.table.chainDepth(ctx.mod, dc, c.dst_clk);
        const terminal = entry.stages[entry.stages.len - 1];
        var internal = std.AutoHashMapUnmanaged(usize, void).empty;
        for (entry.stages) |s| try internal.put(ctx.alloc, s, {});
        const reached = try forwardCells(ctx, terminal);
        for (reached) |cell| {
            if (internal.contains(cell)) continue;
            const slot = try counts.getOrPut(ctx.alloc, cell);
            slot.value_ptr.* = (if (slot.found_existing) slot.value_ptr.* else 0) + 1;
            if (slot.value_ptr.* >= 2) return true;
        }
    }
    return false;
}

fn forwardCells(ctx: *context.Context, start: usize) error{OutOfMemory}![]usize {
    const mod = ctx.mod;
    var reached = std.ArrayListUnmanaged(usize).empty;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var expanded = std.AutoHashMapUnmanaged(usize, void).empty;
    var frontier = std.ArrayListUnmanaged(FrontierBit).empty;
    const q = portBits(mod.cells[start], "Q") orelse return &.{};
    for (q) |b| {
        if (b == .sig) try frontier.append(ctx.alloc, .{ .bit = b.sig, .depth = 0 });
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const fb = frontier.items[head];
        if (seen.contains(fb.bit)) continue;
        try seen.put(ctx.alloc, fb.bit, {});
        const loads = mod.loads_of.get(fb.bit) orelse continue;
        for (loads.items) |loc| {
            const ci = loc.cell orelse continue;
            try reached.append(ctx.alloc, ci);
            const c = mod.cells[ci];
            if (clock.cells.isSequential(c.type)) continue;
            if (clock.cells.isMemoryClock(c.type)) continue;
            if (fb.depth >= 12 or expanded.contains(ci)) continue;
            try expanded.put(ctx.alloc, ci, {});
            for (c.ports) |p| {
                if (p.direction != .output) continue;
                if (!std.mem.eql(u8, p.name, "Y") and !std.mem.eql(u8, p.name, "Q")) continue;
                for (p.bits) |ob| {
                    if (ob == .sig) try frontier.append(ctx.alloc, .{ .bit = ob.sig, .depth = fb.depth + 1 });
                }
            }
        }
    }
    return reached.toOwnedSlice(ctx.alloc);
}

const FrontierBit = struct { bit: u32, depth: u8 };

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
    }
    return null;
}
