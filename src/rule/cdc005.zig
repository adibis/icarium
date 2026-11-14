// SPDX-License-Identifier: Apache-2.0

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
pub const Accum = struct {
    groups: std.AutoHashMapUnmanaged(usize, std.StringHashMapUnmanaged(Group)) = .empty,
};

const Group = struct {
    dsts: std.ArrayListUnmanaged(usize) = .empty,
};

pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var acc = Accum{};
    for (ctx.crossings) |x| try accumulate(&acc, ctx, x);
    return finish(&acc, ctx);
}

pub fn accumulate(acc: *Accum, ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!void {
    if (!try isCandidate(ctx, x)) return;
    const sc = x.src.cell.?;
    const dc = x.dst.cell.?;
    const outer = try acc.groups.getOrPut(ctx.range_alloc, sc);
    if (!outer.found_existing) outer.value_ptr.* = .empty;
    const inner = try outer.value_ptr.getOrPut(ctx.range_alloc, x.dst_clk);
    if (!inner.found_existing) {
        inner.value_ptr.* = .{};
        inner.key_ptr.* = try ctx.range_alloc.dupe(u8, x.dst_clk);
    }
    try inner.value_ptr.dsts.append(ctx.range_alloc, dc);
}

pub fn finish(acc: *Accum, ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var keys = std.ArrayListUnmanaged(Key).empty;
    var oit = acc.groups.iterator();
    while (oit.next()) |oe| {
        var iit = oe.value_ptr.iterator();
        while (iit.next()) |ie| {
            if (ie.value_ptr.dsts.items.len < 2) continue;
            try keys.append(ctx.tmp, .{ .src = oe.key_ptr.*, .clk = ie.key_ptr.*, .dsts = ie.value_ptr.dsts.items });
        }
    }
    std.mem.sort(Key, keys.items, {}, struct {
        fn less(_: void, a: Key, b: Key) bool {
            if (a.src != b.src) return a.src < b.src;
            return std.mem.order(u8, a.clk, b.clk) == .lt;
        }
    }.less);
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    for (keys.items) |k| {
        if (try reconverges(ctx, k.clk, k.dsts)) {
            try out.append(ctx.tmp, try fire(ctx, k));
        }
    }
    return out.toOwnedSlice(ctx.tmp);
}

const Key = struct {
    src: usize,
    clk: []const u8,
    dsts: []usize,
};

fn fire(ctx: *context.Context, k: Key) error{OutOfMemory}!finding.Finding {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    for (k.dsts) |dc| {
        try names.append(ctx.tmp, ctx.mod.cells[dc].name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    const joined = try std.mem.join(ctx.tmp, ", ", names.items);
    const message = try std.fmt.allocPrint(ctx.tmp, "reconvergent synchronizers: source flop {s} drives {d} independent sync chains in domain {s} (dst flops: {s}); independent metastability resolution can produce mismatched synchronized values when these outputs recombine", .{ ctx.mod.cells[k.src].name, k.dsts.len, k.clk, joined });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = ctx.mod.cells[k.src].name,
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
fn reconverges(ctx: *context.Context, clk: []const u8, dsts: []usize) error{OutOfMemory}!bool {
    var counts = std.AutoHashMapUnmanaged(usize, u32).empty;
    for (dsts) |dc| {
        const entry = try ctx.table.chainDepth(ctx.mod, dc, clk);
        const terminal = entry.stages[entry.stages.len - 1];
        var internal = std.AutoHashMapUnmanaged(usize, void).empty;
        for (entry.stages) |s| try internal.put(ctx.tmp, s, {});
        const reached = try forwardCells(ctx, terminal);
        for (reached) |cell| {
            if (internal.contains(cell)) continue;
            const slot = try counts.getOrPut(ctx.tmp, cell);
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
    const q = mod.cells[start].portBits("Q") orelse return &.{};
    for (q) |b| {
        if (b == .sig) try frontier.append(ctx.tmp, .{ .bit = b.sig, .depth = 0 });
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const fb = frontier.items[head];
        if (seen.contains(fb.bit)) continue;
        try seen.put(ctx.tmp, fb.bit, {});
        const loads = mod.loads_of.get(fb.bit) orelse continue;
        for (loads.items) |loc| {
            const ci = loc.cell orelse continue;
            try reached.append(ctx.tmp, ci);
            const c = mod.cells[ci];
            if (clock.cells.isSequential(c.type)) continue;
            if (clock.cells.isMemoryClock(c.type)) continue;
            if (fb.depth >= 12 or expanded.contains(ci)) continue;
            try expanded.put(ctx.tmp, ci, {});
            for (c.ports) |p| {
                if (p.direction != .output) continue;
                if (!std.mem.eql(u8, p.name, "Y") and !std.mem.eql(u8, p.name, "Q")) continue;
                for (p.bits) |ob| {
                    if (ob == .sig) try frontier.append(ctx.tmp, .{ .bit = ob.sig, .depth = fb.depth + 1 });
                }
            }
        }
    }
    return reached.toOwnedSlice(ctx.tmp);
}

const FrontierBit = struct { bit: u32, depth: u8 };
