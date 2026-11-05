const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-004",
    .severity = .err,
    .title = "Multi-bit bus crossing without gating or gray-coding",
    .doc =
    \\A multi-bit path crosses domains with no coherence mechanism:
    \\lanes settle on different cycles, so the destination can sample
    \\a value never sent. Gate the bus behind a synchronized enable,
    \\gray-code it into a multi-bit chain, or assert the promise.
    ,
    .honors = &.{ "cdc_gray", "cdc_static" },
    .check = check,
};

// Bus records only: each must show gating, structural gray, or
// a user promise. Port buses clear by gating alone.
pub fn check(ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!?finding.Finding {
    if (x.kind != .flop_flop_bus and x.kind != .port_flop_bus) return null;
    if (!x.async_per_sdc) return null;
    const dc = x.dst.cell orelse return null;
    if (x.src.cell) |sc| {
        const src_name = ctx.mod.cells[sc].name;
        if (ctx.marks.hasGray(src_name)) return null;
        if (ctx.marks.hasStatic(src_name)) return null;
        if (isMultibitSyncFirstStage(ctx, dc, x.dst_clk) and
            isGrayEncodedSource(ctx, sc)) return null;
    }
    if (try isGatedBusCrossing(ctx, dc, x.dst_clk)) return null;
    const width = x.lanes.len;
    const src_desc = if (x.src.cell) |sc|
        try std.fmt.allocPrint(ctx.alloc, "flop {s}", .{ctx.mod.cells[sc].name})
    else
        try std.fmt.allocPrint(ctx.alloc, "port {s}", .{x.src.port});
    const message = try std.fmt.allocPrint(ctx.alloc,
        "unprotected bus crossing on {s} -> {s}: {d}-bit path with no recognized gating or gray-coding (src: {s}, dst flop: {s})",
        .{ x.src_clk, x.dst_clk, width, src_desc, ctx.mod.cells[dc].name });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = ctx.mod.cells[dc].name,
        .message = message,
    };
}

// Destination Q drives another same-width D lane for lane in the
// same clock: the async-FIFO pointer shape, gray-friendly.
fn isMultibitSyncFirstStage(ctx: *context.Context, dst: usize, dst_clock: []const u8) bool {
    const mod = ctx.mod;
    const c = mod.cells[dst];
    const q = portBits(c, "Q") orelse return false;
    const d = portBits(c, "D") orelse return false;
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
        const nd = portBits(n, "D") orelse continue;
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
// found by a bounded walk that never crosses a flop.
fn isGrayEncodedSource(ctx: *context.Context, src: usize) bool {
    const mod = ctx.mod;
    const d = portBits(mod.cells[src], "D") orelse return false;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(GrayBit).empty;
    for (d) |b| {
        if (b == .sig) frontier.append(ctx.alloc, .{ .bit = b.sig, .depth = 0 }) catch return false;
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const gb = frontier.items[head];
        if (seen.contains(gb.bit)) continue;
        seen.put(ctx.alloc, gb.bit, {}) catch return false;
        if (gb.depth > 8) continue;
        const drv = mod.driver_of.get(gb.bit) orelse continue;
        const ci = drv.cell orelse continue;
        if (std.mem.eql(u8, drv.port, "Q")) continue;
        const c = mod.cells[ci];
        if (std.mem.eql(u8, c.type, "$xor") and hasGraySignature(c)) return true;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b == .sig) frontier.append(ctx.alloc, .{ .bit = b.sig, .depth = gb.depth + 1 }) catch return false;
            }
        }
    }
    return false;
}

const GrayBit = struct { bit: u32, depth: u8 };

fn hasGraySignature(c: ir.types.Cell) bool {
    const a = portBits(c, "A") orelse return false;
    const b = portBits(c, "B") orelse return false;
    if (a.len < 2 or b.len != a.len) return false;
    for (0..a.len - 1) |i| {
        if (a[i + 1] != .sig or b[i] != .sig) return false;
        if (a[i + 1].sig != b[i].sig) return false;
    }
    return b[a.len - 1] != .sig;
}

// Handshake gating, enabled-flop or mux-on-D: the control
// fanin must sit entirely in the destination domain.
fn isGatedBusCrossing(ctx: *context.Context, dst: usize, dst_clock: []const u8) error{OutOfMemory}!bool {
    const mod = ctx.mod;
    const c = mod.cells[dst];
    const flopped = clock.cells.isSequential(c.type) and !clock.cells.isLatch(c.type);
    if (flopped) {
        if (portBits(c, "EN")) |en| {
            var any_sig = false;
            for (en) |b| {
                if (b == .sig) any_sig = true;
            }
            if (any_sig) {
                const fanin = try context.backwardFlopFanin(ctx.alloc, mod, en);
                if (fanin.items.len > 0 and allInDomain(ctx, fanin.items, dst_clock)) return true;
            }
        }
    }
    const d = portBits(c, "D") orelse return false;
    var origins = std.AutoHashMapUnmanaged(usize, void).empty;
    for (d) |db| {
        if (db != .sig) continue;
        const drv = traceThroughBuffers(mod, db.sig) orelse return false;
        try origins.put(ctx.alloc, drv, {});
    }
    if (origins.count() != 1) return false;
    var oit = origins.iterator();
    const origin = oit.next().?.key_ptr.*;
    if (!std.mem.eql(u8, mod.cells[origin].type, "$mux")) return false;
    const s = portBits(mod.cells[origin], "S") orelse return false;
    if (s.len == 0) return false;
    const fanin = try context.backwardFlopFanin(ctx.alloc, mod, s);
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
        const a = portBits(c, "A") orelse return ci;
        const y = portBits(c, "Y") orelse return ci;
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

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
    }
    return null;
}
