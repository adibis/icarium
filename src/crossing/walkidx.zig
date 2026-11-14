// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const ir = @import("../ir.zig");
const reset = @import("../reset.zig");
const sdc = @import("../sdc.zig");

pub const SinkClass = enum { d, srst, arst, clk };

// Sink pins by name on sequential cells: D/SRST/async/CLK. Shared
// with the completeness test, which lists sinks independently.
pub fn sinkClass(cell_type: []const u8, pin: []const u8) ?SinkClass {
    if (clock.cells.isMemoryClock(cell_type)) {
        if (std.mem.eql(u8, pin, "CLK")) return .clk;
        if (std.mem.eql(u8, pin, "ADDR") or std.mem.eql(u8, pin, "DATA") or std.mem.eql(u8, pin, "EN")) return .d;
        return null;
    }
    if (!clock.cells.isSequential(cell_type)) return null;
    if (std.mem.eql(u8, pin, "D")) return .d;
    if (std.mem.eql(u8, pin, "CLK") or std.mem.eql(u8, pin, "G")) return .clk;
    if (clock.cells.isLatch(cell_type) and std.mem.eql(u8, pin, "EN")) return .clk;
    // Flop clock-enables sink: an async enable is a control
    // crossing rules must see, not a wall to walk through.
    if (std.mem.eql(u8, pin, "EN")) return .d;
    if (reset.cells.resetPins(cell_type)) |rp| {
        for (rp.async) |ap| if (std.mem.eql(u8, pin, ap.pin)) return .arst;
        for (rp.sync) |sp| if (std.mem.eql(u8, pin, sp)) return .srst;
    }
    return null;
}

// Memory containers and init data stay opaque; only read/write
// ports participate, and recognized pins never propagate through.
fn isOpaqueMem(cell_type: []const u8) bool {
    return std.mem.startsWith(u8, cell_type, "$mem") and !clock.cells.isMemoryClock(cell_type);
}

// Selects on the mux family broadcast: one select bit steers
// the whole word, so lane mapping must never apply to S.
const mux_family = std.StaticStringMap(void).initComptime(.{
    .{ "$mux", {} },
    .{ "$pmux", {} },
    .{ "$ternary", {} },
    .{ "$bwmux", {} },
});

// Control pins steer every output bit at once: a toggling
// select corrupts the whole word, so they always broadcast.
fn isControlPin(cell_type: []const u8, pin: []const u8) bool {
    if (std.mem.eql(u8, pin, "S") and mux_family.get(cell_type) != null) return true;
    return std.mem.eql(u8, pin, "EN");
}

fn laneParallel(cell_type: []const u8) bool {
    for ([_][]const u8{ "$not", "$and", "$or", "$xor", "$xnor", "$mux", "$pmux", "$ternary", "$bwmux", "$tribuf" }) |t| {
        if (std.mem.eql(u8, cell_type, t)) return true;
    }
    return false;
}

// One resolved fanout edge: every string decision the walker
// needs, answered once at build instead of per visit. Cell-less
// hash locs, blackboxes, and opaque memories are dropped here;
// the walker skipped all three without emitting, so the index
// only stores edges it would have acted on. Null-cell loads are
// typed output ports, added explicitly: block exits the walker
// ends with a pair instead of walking past.
pub const Load = struct {
    cell: ?usize,
    pin: []const u8,
    lane: usize,
    sink: ?SinkClass,
    control: bool,
    pin_ctl: bool,
    pin_b: bool,
};

pub const CellInfo = struct {
    seq_or_memclock: bool,
    parallel: bool,
    pmux: bool,
};

// Resolved walk index: CSR fanout over the bit universe plus
// per-cell flags. Rebuilds the hash fanout as flat arrays, so
// a visit costs indexing and integer compares only. Immutable
// after build: worker threads share one index, each with its
// own Visit state.
pub const Index = struct {
    off: []u32,
    flat: []Load,
    cells: []CellInfo,
    nbits: usize,

    pub const none: u32 = 0xffff_ffff;

    pub fn loads(self: *const Index, bit: u32) []const Load {
        return self.flat[self.off[bit]..self.off[bit + 1]];
    }

    pub fn allocVisit(self: *const Index, alloc: std.mem.Allocator) error{OutOfMemory}!Visit {
        const stamp = try alloc.alloc(u32, self.nbits);
        @memset(stamp, 0);
        return .{
            .stamp = stamp,
            .prev = try alloc.alloc(u32, self.nbits),
            .via = try alloc.alloc(u32, self.nbits),
            .gen = 0,
        };
    }

    pub fn build(
        alloc: std.mem.Allocator,
        mod: *const ir.types.Module,
        controls: []const clock.trace.ControlPin,
        model: *const sdc.model.Model,
    ) error{OutOfMemory}!Index {
        var max_bit: u32 = 0;
        for (mod.cells) |c| {
            for (c.ports) |p| {
                for (p.bits) |b| {
                    if (b == .sig and b.sig > max_bit) max_bit = b.sig;
                }
            }
        }
        for (mod.ports) |p| {
            for (p.bits) |b| {
                if (b == .sig and b.sig > max_bit) max_bit = b.sig;
            }
        }
        std.debug.assert(max_bit != none);

        const cells = try alloc.alloc(CellInfo, mod.cells.len);
        for (mod.cells, 0..) |c, ci| {
            cells[ci] = .{
                .seq_or_memclock = clock.cells.isSequential(c.type) or clock.cells.isMemoryClock(c.type),
                .parallel = laneParallel(c.type),
                .pmux = std.mem.eql(u8, c.type, "$pmux"),
            };
        }

        // CSR fanout: count, prefix-sum, fill. Count sweeps the
        // hash fanout once; every later lookup is two array reads.
        const off = try alloc.alloc(u32, @as(usize, max_bit) + 2);
        @memset(off, 0);
        var it = mod.loads_of.iterator();
        while (it.next()) |kv| {
            const b = kv.key_ptr.*;
            for (kv.value_ptr.items) |loc| {
                const ci = loc.cell orelse continue;
                const c = mod.cells[ci];
                if (isOpaqueMem(c.type)) continue;
                if (c.blackbox) continue;
                off[b + 1] += 1;
            }
        }
        // Untyped ports stay invisible: no declared clock, unknown
        // noise either way. Port typing resolves once at build.
        for (mod.ports) |p| {
            if (p.direction != .output) continue;
            if (sdc.model.portClock(model, p.name) == null) continue;
            for (p.bits) |b| {
                if (b != .sig) continue;
                off[b.sig + 1] += 1;
            }
        }
        var total: u32 = 0;
        for (0..@as(usize, max_bit) + 1) |b| {
            const n = off[b + 1];
            off[b] = total;
            total += n;
        }
        off[max_bit + 1] = total;
        const flat = try alloc.alloc(Load, total);
        var cursor = try alloc.dupe(u32, off[0 .. max_bit + 1]);
        defer alloc.free(cursor);
        // Bit-ascending fill: each bit's loads keep their netlist
        // order, so BFS discovery (and every hop path) matches the
        // hash-map walk exactly. Hash-order fill would only differ
        // in which parent a reconvergent bit keeps, but identical
        // output is worth the ordered pass.
        var b: u32 = 0;
        while (true) {
            if (mod.loads_of.get(b)) |locs| {
                for (locs.items) |loc| {
                    const ci = loc.cell orelse continue;
                    const c = mod.cells[ci];
                    if (isOpaqueMem(c.type)) continue;
                    if (c.blackbox) continue;
                    flat[cursor[b]] = .{
                        .cell = ci,
                        .pin = loc.port,
                        .lane = laneOf(c, loc.port, b),
                        .sink = sinkClass(c.type, loc.port),
                        .control = isControl(controls, ci, loc.port),
                        .pin_ctl = isControlPin(c.type, loc.port),
                        .pin_b = std.mem.eql(u8, loc.port, "B"),
                    };
                    cursor[b] += 1;
                }
            }
            if (b == max_bit) break;
            b += 1;
        }
        // Port loads append after cell loads per bit, in netlist
        // port order: existing hop paths never shift, and ports
        // need no per-bit scan of their own.
        for (mod.ports) |p| {
            if (p.direction != .output) continue;
            if (sdc.model.portClock(model, p.name) == null) continue;
            for (p.bits, 0..) |bit, lane| {
                if (bit != .sig) continue;
                flat[cursor[bit.sig]] = .{
                    .cell = null,
                    .pin = p.name,
                    .lane = lane,
                    .sink = null,
                    .control = false,
                    .pin_ctl = false,
                    .pin_b = false,
                };
                cursor[bit.sig] += 1;
            }
        }

        return .{
            .off = off,
            .flat = flat,
            .cells = cells,
            .nbits = @as(usize, max_bit) + 1,
        };
    }
};

// Per-walk visit state: generation stamps plus parent links
// for hop reconstruction. One per worker thread; walks never
// share it, so concurrent sources cannot corrupt each other.
pub const Visit = struct {
    stamp: []u32,
    prev: []u32,
    via: []u32,
    gen: u32,

    pub fn nextGen(self: *Visit) void {
        self.gen += 1;
        if (self.gen == Index.none) {
            @memset(self.stamp, 0);
            self.gen = 1;
        }
    }
};

fn laneOf(c: ir.types.Cell, pin: []const u8, bit: u32) usize {
    for (c.ports) |p| {
        if (!std.mem.eql(u8, p.name, pin)) continue;
        for (p.bits, 0..) |b, i| {
            if (b == .sig and b.sig == bit) return i;
        }
    }
    return 0;
}

// Control pins are few (clock-path muxes and gates); binary
// search over the sorted control index at build time only.
fn isControl(controls: []const clock.trace.ControlPin, ci: usize, pin: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = controls.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cp = controls[mid];
        if (cp.cell < ci or (cp.cell == ci and std.mem.lessThan(u8, cp.pin, pin))) {
            lo = mid + 1;
        } else if (cp.cell == ci and std.mem.eql(u8, cp.pin, pin)) {
            return true;
        } else {
            hi = mid;
        }
    }
    return false;
}
