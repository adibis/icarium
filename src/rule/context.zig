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
    // One batch or the whole report: rules never see past
    // this slice, so streaming feeds chunks through it.
    crossings: []const crossing.enumerate.Crossing,
    // Fire strings and probes die here with the batch; the
    // registry copies out kept findings, ledgers keep alloc.
    tmp: std.mem.Allocator,
    // Range ledgers die here at range end; whole-report runs
    // point it at alloc, where one range is the whole run.
    range_alloc: std.mem.Allocator,
    table: *sync.table.Table,
    marks: *const sync.attrs.Marks,
    reset_view: *const reset.trace.View,
    reset_syncs: *const reset.chains.Syncs,
    buses: []const crossing.enumerate.Crossing,
    cfg: Config,
    alloc: std.mem.Allocator,

    // Binary search over the sorted bus index: a linear scan
    // costs O(buses) per crossing per rule — quadratic at scale.
    pub fn isBusMember(ctx: *const Context, x: crossing.enumerate.Crossing) bool {
        if (x.kind != .flop_flop_bit and x.kind != .port_flop and x.kind != .port_flop_untyped) return false;
        const xdc = x.dst.cell orelse return false;
        var lo: usize = 0;
        var hi: usize = ctx.buses.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const b = ctx.buses[mid];
            const ord = busOrder(x.src.cell, x.src.port, xdc, x.dst.port, b);
            if (ord == .lt) {
                hi = mid;
            } else if (ord == .gt) {
                lo = mid + 1;
            } else {
                return true;
            }
        }
        return false;
    }
};

fn busOrder(scell: ?usize, sport: []const u8, dcell: usize, dport: []const u8, b: crossing.enumerate.Crossing) std.math.Order {
    const snull = scell == null;
    const bnull = b.src.cell == null;
    if (snull != bnull) return if (snull) .lt else .gt;
    if (scell) |sc| {
        if (sc != b.src.cell.?) return std.math.order(sc, b.src.cell.?);
    }
    const sp = std.mem.order(u8, sport, b.src.port);
    if (sp != .eq) return sp;
    if (dcell != b.dst.cell.?) return std.math.order(dcell, b.dst.cell.?);
    return std.mem.order(u8, dport, b.dst.port);
}

fn busLess(_: void, a: crossing.enumerate.Crossing, b: crossing.enumerate.Crossing) bool {
    return busOrder(a.src.cell, a.src.port, a.dst.cell.?, a.dst.port, b) == .lt;
}

pub fn collectBuses(
    alloc: std.mem.Allocator,
    crossings: []const crossing.enumerate.Crossing,
) error{OutOfMemory}![]crossing.enumerate.Crossing {
    var out = std.ArrayListUnmanaged(crossing.enumerate.Crossing).empty;
    for (crossings) |x| {
        // Null destinations never match a lookup; dropping them
        // here keeps the index total without a null branch.
        if (x.dst.cell == null) continue;
        if (x.kind == .flop_flop_bus or x.kind == .port_flop_bus) try out.append(alloc, x);
    }
    std.mem.sort(crossing.enumerate.Crossing, out.items, {}, busLess);
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
            const bits = c.portBits(pin) orelse continue;
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

const FaninBit = struct { bit: u32, depth: u8 };

// Backward BFS through combinational cells, collecting the
// top-level input ports reached. Flop Q stops the walk: a
// flopped source belongs to RDC-004's case, never this one.
// Cost: O(12-hop cone), visited-guarded; callers pay per call.
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

// Flop cells whose Q feeds the bits through combinational logic.
// Ports and constants end the walk; twelve hops bound it.
// Cost: O(12-hop cone), visited-guarded; callers pay per call.
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

pub fn portOfBit(mod: *const ir.types.Module, bit: u32) ?[]const u8 {
    for (mod.ports) |p| {
        for (p.bits) |b| {
            if (b == .sig and b.sig == bit) return p.name;
        }
    }
    return null;
}
