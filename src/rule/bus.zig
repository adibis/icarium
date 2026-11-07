const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const ir = @import("../ir.zig");

// Structural bus-crossing tests shared by the bus rules: gating
// detection and gray-encode recognition. One home avoids drift
// between the rule that demands them and the ones that exempt.

// Destination Q drives another same-width D lane for lane in the
// same clock: the async-FIFO pointer shape, gray-friendly.
pub fn isMultibitSyncFirstStage(ctx: *context.Context, dst: usize, dst_clock: []const u8) bool {
    const mod = ctx.mod;
    const c = mod.cells[dst];
    const q = c.portBits("Q") orelse return false;
    const d = c.portBits("D") orelse return false;
    if (q.len < 2 or d.len != q.len) return false;
    for (q) |qb| {
        if (qb != .sig) return false;
    }
    const loads = mod.loads_of.get(q[0].sig) orelse return false;
    for (loads.items) |loc| {
        const nci = loc.cell orelse continue;
        if (nci == dst) continue;
        if (!std.mem.eql(u8, loc.port, "D")) continue;
        const n = mod.cells[nci];
        if (!clock.cells.isSequential(n.type)) continue;
        const nd = n.portBits("D") orelse continue;
        if (nd.len != q.len) continue;
        var aligned = true;
        for (nd, q) |db, qb| {
            if (db != .sig or db.sig != qb.sig) aligned = false;
        }
        if (!aligned) continue;
        const dom = ctx.table.domainOf(nci) orelse continue;
        if (std.mem.eql(u8, dom.name, dst_clock)) return true;
    }
    return false;
}

// Canonical gray encode in the source fanin: shifted $xor,
// found by a bounded walk that never crosses a flop. The walk
// runs once per cell; repeats read the memo, so broadcast
// batches stop paying a walk per crossing.
pub fn isGrayEncodedSource(ctx: *context.Context, src: usize) bool {
    if (ctx.table.grayVerdict(src)) |v| return v;
    var arena = ctx.table.workArena();
    defer arena.deinit();
    const v = grayWalk(ctx, arena.allocator(), src);
    ctx.table.storeGray(src, v);
    return v;
}

fn grayWalk(ctx: *context.Context, alloc: std.mem.Allocator, src: usize) bool {
    const mod = ctx.mod;
    const d = mod.cells[src].portBits("D") orelse return false;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(GrayBit).empty;
    for (d) |b| {
        if (b == .sig) frontier.append(alloc, .{ .bit = b.sig, .depth = 0 }) catch return false;
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const gb = frontier.items[head];
        if (seen.contains(gb.bit)) continue;
        seen.put(alloc, gb.bit, {}) catch return false;
        if (gb.depth > 8) continue;
        const drv = mod.driver_of.get(gb.bit) orelse continue;
        const ci = drv.cell orelse continue;
        if (std.mem.eql(u8, drv.port, "Q")) continue;
        const c = mod.cells[ci];
        if (std.mem.eql(u8, c.type, "$xor") and hasGraySignature(c)) return true;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b == .sig) frontier.append(alloc, .{ .bit = b.sig, .depth = gb.depth + 1 }) catch return false;
            }
        }
    }
    return false;
}

const GrayBit = struct { bit: u32, depth: u8 };

fn hasGraySignature(c: ir.types.Cell) bool {
    const a = c.portBits("A") orelse return false;
    const b = c.portBits("B") orelse return false;
    if (a.len < 2 or b.len != a.len) return false;
    for (0..a.len - 1) |i| {
        if (a[i + 1] != .sig or b[i] != .sig) return false;
        if (a[i + 1].sig != b[i].sig) return false;
    }
    return b[a.len - 1] != .sig;
}

// Muxed-clock endpoints carry several legs: a verdict needing
// one exact domain cannot prove membership and stays out,
// leaving the pair to the MULTCLK leg-pair report (CDC-026).
pub fn isMuxedClock(ctx: *context.Context, cell: usize) bool {
    const d = ctx.table.domainOf(cell) orelse return true;
    return d.legs.len > 1;
}

// Handshake gating, enabled-flop or mux-on-D: the control
// fanin must sit entirely in the destination domain. The walk
// runs once per (destination, clock); misses burn a throwaway
// arena, so nothing per-crossing reaches any batch arena.
pub fn isGatedBusCrossing(ctx: *context.Context, dst: usize, dst_clock: []const u8) error{OutOfMemory}!bool {
    if (ctx.table.gatingVerdict(dst, dst_clock)) |v| return v;
    var arena = ctx.table.workArena();
    defer arena.deinit();
    const v = try gatedWalk(ctx, arena.allocator(), dst, dst_clock);
    try ctx.table.storeGating(dst, dst_clock, v);
    return v;
}

fn gatedWalk(ctx: *context.Context, scratch: std.mem.Allocator, dst: usize, dst_clock: []const u8) error{OutOfMemory}!bool {
    const mod = ctx.mod;
    const c = mod.cells[dst];
    const flopped = clock.cells.isSequential(c.type) and !clock.cells.isLatch(c.type);
    if (flopped) {
        if (c.portBits("EN")) |en| {
            var any_sig = false;
            for (en) |b| {
                if (b == .sig) any_sig = true;
            }
            if (any_sig) {
                const fanin = try context.backwardFlopFanin(scratch, mod, en);
                if (fanin.items.len > 0 and allInDomain(ctx, fanin.items, dst_clock)) return true;
            }
        }
    }
    const d = c.portBits("D") orelse return false;
    var origins = std.AutoHashMapUnmanaged(usize, void).empty;
    for (d) |db| {
        if (db != .sig) continue;
        const drv = traceThroughBuffers(mod, db.sig) orelse return false;
        try origins.put(scratch, drv, {});
    }
    if (origins.count() != 1) return false;
    var oit = origins.iterator();
    const origin = oit.next().?.key_ptr.*;
    if (!std.mem.eql(u8, mod.cells[origin].type, "$mux")) return false;
    const s = mod.cells[origin].portBits("S") orelse return false;
    if (s.len == 0) return false;
    const fanin = try context.backwardFlopFanin(scratch, mod, s);
    if (fanin.items.len == 0) return false;
    return allInDomain(ctx, fanin.items, dst_clock);
}

fn allInDomain(ctx: *context.Context, cells: []usize, dst_clock: []const u8) bool {
    for (cells) |ci| {
        const dom = ctx.table.domainOf(ci) orelse return false;
        if (!std.mem.eql(u8, dom.name, dst_clock)) return false;
    }
    return true;
}

const buffer_types = std.StaticStringMap(void).initComptime(.{
    .{ "$not", {} },
    .{ "$buf", {} },
    .{ "$pos", {} },
    .{ "$_BUF_", {} },
    .{ "$_NOT_", {} },
});

// Step back through transparent buffers, two at most. Past
// budget the driver returns anyway, failing the type check.
fn traceThroughBuffers(mod: *const ir.types.Module, bit: u32) ?usize {
    var cur = bit;
    var hops: u8 = 0;
    while (true) {
        const drv = mod.driver_of.get(cur) orelse return null;
        const ci = drv.cell orelse return null;
        const c = mod.cells[ci];
        if (buffer_types.get(c.type) == null) return ci;
        if (hops >= 2) return ci;
        const a = c.portBits("A") orelse return ci;
        const y = c.portBits("Y") orelse return ci;
        if (a.len != y.len) return ci;
        const idx = yIndex(y, cur) orelse return ci;
        if (a[idx] != .sig) return ci;
        cur = a[idx].sig;
        hops += 1;
    }
}

fn yIndex(y: []ir.bits.Bit, bit: u32) ?usize {
    for (y, 0..) |b, i| {
        if (b == .sig and b.sig == bit) return i;
    }
    return null;
}
