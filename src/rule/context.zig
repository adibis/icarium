const std = @import("std");
const clock = @import("../clock.zig");
const crossing = @import("../crossing.zig");
const ir = @import("../ir.zig");
const reset = @import("../reset.zig");
const sdc = @import("../sdc.zig");
const sync = @import("../sync.zig");

// Rule views plus the sync table (its memo is the only
// mutation rules may cause) and an index of bus records.
pub const Config = struct {
    sync_depth: u32 = 2,
    cdc010_heuristic: bool = true,
    cdc018_threshold: u32 = 4,
    sync_primitives: []const []const u8 = &.{},
};

pub const Context = struct {
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    report: *const crossing.enumerate.Report,
    table: *sync.table.Table,
    marks: *const sync.attrs.Marks,
    reset_view: *const reset.trace.View,
    reset_syncs: *const reset.chains.Syncs,
    buses: []const crossing.enumerate.Crossing,
    cfg: Config,
    alloc: std.mem.Allocator,

    pub fn isBusMember(ctx: *const Context, x: crossing.enumerate.Crossing) bool {
        if (x.kind != .flop_flop_bit and x.kind != .port_flop and x.kind != .port_flop_untyped) return false;
        for (ctx.buses) |b| {
            if ((x.src.cell == null) != (b.src.cell == null)) continue;
            if (x.src.cell) |sc| {
                if (sc != b.src.cell.?) continue;
            }
            const bdc = b.dst.cell orelse continue;
            const xdc = x.dst.cell orelse continue;
            if (std.mem.eql(u8, b.src.port, x.src.port) and
                bdc == xdc and std.mem.eql(u8, b.dst.port, x.dst.port))
            {
                return true;
            }
        }
        return false;
    }
};

pub fn collectBuses(
    alloc: std.mem.Allocator,
    report: *const crossing.enumerate.Report,
) error{OutOfMemory}![]crossing.enumerate.Crossing {
    var out = std.ArrayListUnmanaged(crossing.enumerate.Crossing).empty;
    for (report.crossings) |x| {
        if (x.kind == .flop_flop_bus or x.kind == .port_flop_bus) try out.append(alloc, x);
    }
    return out.toOwnedSlice(alloc);
}

// Cells whose output transitively drives a flop clock. Reading
// a clock on their inputs is distribution, never a bug.
pub fn clockNetworkCells(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
) error{OutOfMemory}!std.AutoHashMapUnmanaged(usize, void) {
    var cells = std.AutoHashMapUnmanaged(usize, void).empty;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(u32).empty;
    for (mod.cells) |c| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        for ([_][]const u8{ "CLK", "G" }) |pin| {
            const bits = portBits(c, pin) orelse continue;
            for (bits) |b| {
                if (b == .sig) try frontier.append(alloc, b.sig);
            }
        }
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const bit = frontier.items[head];
        if (seen.contains(bit)) continue;
        try seen.put(alloc, bit, {});
        const drv = mod.driver_of.get(bit) orelse continue;
        const ci = drv.cell orelse continue;
        if (cells.contains(ci)) continue;
        try cells.put(alloc, ci, {});
        for (mod.cells[ci].ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b == .sig) try frontier.append(alloc, b.sig);
            }
        }
    }
    return cells;
}

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
    }
    return null;
}

const FaninBit = struct { bit: u32, depth: u8 };

// Flop cells whose Q feeds the bits through combinational logic.
// Ports and constants end the walk; twelve hops bound it.
// Backward BFS through combinational cells, collecting the
// top-level input ports reached. Flop Q stops the walk: a
// flopped source belongs to RDC-004's case, never this one.
pub fn backwardPortFanin(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    start: []ir.bits.Bit,
) error{OutOfMemory}![][]const u8 {
    var ports = std.StringHashMapUnmanaged(void).empty;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(FaninBit).empty;
    for (start) |b| {
        if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = 0 });
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const fb = frontier.items[head];
        if (seen.contains(fb.bit)) continue;
        try seen.put(alloc, fb.bit, {});
        const drv = mod.driver_of.get(fb.bit) orelse continue;
        const ci = drv.cell orelse {
            try ports.put(alloc, drv.port, {});
            continue;
        };
        if (std.mem.eql(u8, drv.port, "Q")) continue;
        if (fb.depth >= 12) continue;
        for (mod.cells[ci].ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = fb.depth + 1 });
            }
        }
    }
    var out = std.ArrayListUnmanaged([]const u8).empty;
    var it = ports.iterator();
    while (it.next()) |e| try out.append(alloc, e.key_ptr.*);
    return out.toOwnedSlice(alloc);
}

pub fn backwardFlopFanin(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    start: []ir.bits.Bit,
) error{OutOfMemory}!std.ArrayListUnmanaged(usize) {
    var flops = std.ArrayListUnmanaged(usize).empty;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(FaninBit).empty;
    for (start) |b| {
        if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = 0 });
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const fb = frontier.items[head];
        if (seen.contains(fb.bit)) continue;
        try seen.put(alloc, fb.bit, {});
        const drv = mod.driver_of.get(fb.bit) orelse continue;
        const ci = drv.cell orelse continue;
        if (std.mem.eql(u8, drv.port, "Q")) {
            try flops.append(alloc, ci);
            continue;
        }
        if (fb.depth >= 12) continue;
        for (mod.cells[ci].ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = fb.depth + 1 });
            }
        }
    }
    return flops;
}
