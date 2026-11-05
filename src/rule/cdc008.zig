const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");
const sdc = @import("../sdc.zig");

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
            const bits = portBits(c, pin) orelse continue;
            for (bits) |b| {
                if (b == .sig) try clock_bits.put(ctx.alloc, b.sig, {});
            }
        }
    }
    for (mod.ports) |p| {
        if (p.direction != .input) continue;
        if (sdc.model.rootClock(ctx.model, p.name) == null) continue;
        for (p.bits) |b| {
            if (b == .sig) try clock_bits.put(ctx.alloc, b.sig, {});
        }
    }
    if (clock_bits.count() == 0) return &.{};
    const net_cells = try clockNetworkCells(ctx);

    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var seen = std.AutoHashMapUnmanaged(Triple, void).empty;
    for (mod.cells, 0..) |c, ci| {
        if (net_cells.contains(ci)) continue;
        for (c.ports, 0..) |p, pi| {
            if (p.direction == .output) continue;
            if (std.mem.eql(u8, p.name, "CLK")) continue;
            if (clock.cells.isLatch(c.type) and
                (std.mem.eql(u8, p.name, "G") or std.mem.eql(u8, p.name, "EN"))) continue;
            for (p.bits, 0..) |b, idx| {
                if (b != .sig or !clock_bits.contains(b.sig)) continue;
                const key = Triple{ .bit = b.sig, .cell = ci, .pin = pi };
                if (seen.contains(key)) continue;
                try seen.put(ctx.alloc, key, {});
                const label = try bitLabel(ctx.alloc, mod, b.sig);
                const message = try std.fmt.allocPrint(ctx.alloc,
                    "clock signal {s} used as data: connected to {s}.{s}[{d}] (cell type {s})",
                    .{ label, c.name, p.name, idx, c.type });
                try out.append(ctx.alloc, .{
                    .rule = rule.id,
                    .severity = rule.severity,
                    .dst = c.name,
                    .message = message,
                });
            }
        }
    }
    return out.toOwnedSlice(ctx.alloc);
}

const Triple = struct { bit: u32, cell: usize, pin: usize };

// Cells whose output transitively drives a flop clock. Reading
// a clock on their inputs is distribution, never a bug.
fn clockNetworkCells(ctx: *context.Context) error{OutOfMemory}!std.AutoHashMapUnmanaged(usize, void) {
    const mod = ctx.mod;
    var cells = std.AutoHashMapUnmanaged(usize, void).empty;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(u32).empty;
    for (mod.cells) |c| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        for ([_][]const u8{ "CLK", "G" }) |pin| {
            const bits = portBits(c, pin) orelse continue;
            for (bits) |b| {
                if (b == .sig) try frontier.append(ctx.alloc, b.sig);
            }
        }
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const bit = frontier.items[head];
        if (seen.contains(bit)) continue;
        try seen.put(ctx.alloc, bit, {});
        const drv = mod.driver_of.get(bit) orelse continue;
        const ci = drv.cell orelse continue;
        if (cells.contains(ci)) continue;
        try cells.put(ctx.alloc, ci, {});
        for (mod.cells[ci].ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b == .sig) try frontier.append(ctx.alloc, b.sig);
            }
        }
    }
    return cells;
}

fn bitLabel(alloc: std.mem.Allocator, mod: *const ir.types.Module, bit: u32) error{OutOfMemory}![]const u8 {
    for (mod.ports) |p| {
        for (p.bits) |b| {
            if (b == .sig and b.sig == bit) return p.name;
        }
    }
    return std.fmt.allocPrint(alloc, "net@{d}", .{bit});
}

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
    }
    return null;
}
