// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");
const sdc = @import("../sdc.zig");
const sync = @import("../sync.zig");

pub const rule = registry.Rule{
    .id = "CDC-008",
    .severity = .err,
    .title = "Clock signal used as data",
    .doc =
    \\A bit that drives a flop clock (or an SDC clock port) also feeds
    \\a non-clock input: clocks ride low-skew networks and sampling
    \\them as data breaks STA. Clock-distribution cells, clock pins,
    \\and off-chip forwarding are exempt; the rest is a wiring bug.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// Connection walk outside the distribution network: every clock
// bit on a data pin fires once. Latch gates read as clock pins.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    const mod = ctx.mod;
    var clock_bits = std.AutoHashMapUnmanaged(u32, void).empty;
    for (mod.cells) |c| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        for ([_][]const u8{ "CLK", "G" }) |pin| {
            const bits = c.portBits(pin) orelse continue;
            for (bits) |b| {
                if (b == .sig) try clock_bits.put(ctx.tmp, b.sig, {});
            }
        }
    }
    for (mod.ports) |p| {
        if (p.direction != .input) continue;
        if (sdc.model.rootClock(ctx.model, p.name) == null) continue;
        for (p.bits) |b| {
            if (b == .sig) try clock_bits.put(ctx.tmp, b.sig, {});
        }
    }
    if (clock_bits.count() == 0) return &.{};
    // Walks die per cell: clock cones span the design, and one
    // retained walk per cell exhausts memory at full-chip scale.
    var backing = ctx.table.workArena();
    defer backing.deinit();
    const parent = backing.allocator();
    var scratch = std.heap.ArenaAllocator.init(parent);
    defer scratch.deinit();
    const net_cells = try context.clockNetworkCells(parent, ctx.mod);

    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var seen = std.AutoHashMapUnmanaged(Triple, void).empty;
    for (mod.cells, 0..) |c, ci| {
        if (net_cells.contains(ci)) continue;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            if (skipPin(ctx, c, p.name)) continue;
            for (p.bits) |b| {
                if (b != .sig or !clock_bits.contains(b.sig)) continue;
                if (clock.cells.isTransparent(c.type)) {
                    _ = scratch.reset(.retain_capacity);
                    const terms = try terminals(scratch.allocator(), mod, ci, &net_cells);
                    for (terms) |t| {
                        const tc = mod.cells[t.cell];
                        if (skipPin(ctx, tc, t.pin)) continue;
                        try fire(ctx, mod, &seen, &out, b.sig, t.cell, t.pin, t.idx);
                    }
                } else {
                    const idx = pinIndex(c, p.name, b.sig);
                    try fire(ctx, mod, &seen, &out, b.sig, ci, p.name, idx);
                }
            }
        }
    }
    return out.toOwnedSlice(ctx.tmp);
}

fn skipPin(ctx: *context.Context, c: ir.types.Cell, pin: []const u8) bool {
    if (std.mem.eql(u8, pin, "CLK")) return true;
    if (clock.cells.isLatch(c.type) and
        (std.mem.eql(u8, pin, "G") or std.mem.eql(u8, pin, "EN"))) return true;
    // Clock pins on a recognised macro are clocks, not data:
    // the macro names its own clock legs, XPM rigidly so.
    if (c.blackbox and
        sync.primitives.isSyncPrimitive(c.type, ctx.cfg.sync_primitives) and
        sync.primitives.isClockPin(pin)) return true;
    return false;
}

fn fire(
    ctx: *context.Context,
    mod: *const ir.types.Module,
    seen: *std.AutoHashMapUnmanaged(Triple, void),
    out: *std.ArrayListUnmanaged(finding.Finding),
    bit: u32,
    ci: usize,
    pin: []const u8,
    idx: usize,
) error{OutOfMemory}!void {
    const c = mod.cells[ci];
    const key = Triple{ .bit = bit, .cell = ci, .pin = pinIndex(c, pin, null) };
    if (seen.contains(key)) return;
    try seen.put(ctx.tmp, key, {});
    const label = try bitLabel(ctx.tmp, mod, bit);
    const message = try std.fmt.allocPrint(ctx.tmp, "clock signal {s} used as data: connected to {s}.{s}[{d}] (cell type {s})", .{ label, c.name, pin, idx, c.type });
    try out.append(ctx.tmp, .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = c.name,
        .message = message,
    });
}

// Index of the pin holding the bit, or the pin's own index when
// no bit is given: arrival identity for the dedup key.
fn pinIndex(c: ir.types.Cell, pin: []const u8, bit: ?u32) usize {
    for (c.ports, 0..) |p, pi| {
        if (!std.mem.eql(u8, p.name, pin)) continue;
        if (bit) |want| {
            for (p.bits, 0..) |b, i| {
                if (b == .sig and b.sig == want) return i;
            }
            return 0;
        }
        return pi;
    }
    return 0;
}

const Terminal = struct { cell: usize, pin: []const u8, idx: usize };

// Transparent cells pass the verdict downstream: a buffer on a
// clock bit is distribution, and only its first opaque load can
// sample the clock. Dangling chains end silently, never as bugs.
fn terminals(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    start: usize,
    net_cells: *const std.AutoHashMapUnmanaged(usize, void),
) error{OutOfMemory}![]Terminal {
    var out = std.ArrayListUnmanaged(Terminal).empty;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(u32).empty;
    for (mod.cells[start].ports) |p| {
        if (p.direction != .output) continue;
        for (p.bits) |b| {
            if (b == .sig) try frontier.append(alloc, b.sig);
        }
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const bit = frontier.items[head];
        if (seen.contains(bit)) continue;
        try seen.put(alloc, bit, {});
        const loads = mod.loads_of.get(bit) orelse continue;
        for (loads.items) |loc| {
            const ci = loc.cell orelse continue;
            if (net_cells.contains(ci)) continue;
            const c = mod.cells[ci];
            if (clock.cells.isTransparent(c.type)) {
                for (c.ports) |p| {
                    if (p.direction != .output) continue;
                    for (p.bits) |b| {
                        if (b == .sig) try frontier.append(alloc, b.sig);
                    }
                }
                continue;
            }
            const port = c.portBits(loc.port) orelse continue;
            for (port, 0..) |b, i| {
                if (b == .sig and b.sig == bit) try out.append(alloc, .{ .cell = ci, .pin = loc.port, .idx = i });
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

const Triple = struct { bit: u32, cell: usize, pin: usize };

fn bitLabel(alloc: std.mem.Allocator, mod: *const ir.types.Module, bit: u32) error{OutOfMemory}![]const u8 {
    for (mod.ports) |p| {
        for (p.bits) |b| {
            if (b == .sig and b.sig == bit) return p.name;
        }
    }
    return std.fmt.allocPrint(alloc, "net@{d}", .{bit});
}
