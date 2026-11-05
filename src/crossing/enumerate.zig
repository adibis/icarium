const std = @import("std");
const clock = @import("../clock.zig");
const id = @import("id.zig");
const ir = @import("../ir.zig");
const reset = @import("../reset.zig");
const sdc = @import("../sdc.zig");

pub const Kind = enum {
    flop_flop_bit,
    flop_flop_bus,
    port_flop,
    port_flop_untyped,
    clock_sink,
    clock_control,
};

pub const Endpoint = struct {
    cell: ?usize,
    port: []const u8,
    bit: u32,
    lane: usize,
};

pub const Lane = struct { src_lane: usize, dst_lane: usize };

pub const Crossing = struct {
    id: []const u8,
    kind: Kind,
    src: Endpoint,
    dst: Endpoint,
    src_clk: []const u8,
    dst_clk: []const u8,
    async_per_sdc: bool,
    hops: []usize,
    lanes: []Lane,
    instance_path: [][]const u8,
    src_loc: []const u8,
    dst_loc: []const u8,
};

pub const Report = struct {
    // Heap-owned, matching Module: copying a live arena orphans
    // later allocations from deinit (see ir/types.zig).
    backing: *std.heap.ArenaAllocator,
    crossings: []Crossing,

    pub fn deinit(self: *Report) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }
};

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

pub fn enumerate(
    parent: std.mem.Allocator,
    mod: *const ir.types.Module,
    clock_asg: *const clock.trace.Assignment,
    model: *const sdc.model.Model,
) error{OutOfMemory}!Report {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();

    var clock_of = std.AutoHashMapUnmanaged(usize, clock.trace.Domain){};
    for (clock_asg.flops) |f| try clock_of.put(alloc, f.cell, f.domain);

    var en = Enumerator{
        .mod = mod,
        .model = model,
        .alloc = alloc,
        .clock_of = &clock_of,
        .bit_domains = &clock_asg.bit_domains,
        .controls = clock_asg.controls,
    };
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    for (mod.cells, 0..) |c, ci| {
        if (clock.cells.isSequential(c.type)) {
            if (portBits(c, "Q")) |q| {
                for (q, 0..) |b, lane| {
                    if (b != .sig) continue;
                    try en.walkFrom(ci, "Q", b.sig, lane, &pairs);
                }
            }
        } else if (clock.cells.isMemRead(c.type)) {
            if (portBits(c, "DATA")) |d| {
                for (d, 0..) |b, lane| {
                    if (b != .sig) continue;
                    try en.walkFrom(ci, "DATA", b.sig, lane, &pairs);
                }
            }
        } else if (c.blackbox) {
            for (c.ports) |p| {
                if (p.direction == .input) continue;
                for (p.bits, 0..) |b, lane| {
                    if (b != .sig) continue;
                    try en.walkFrom(ci, p.name, b.sig, lane, &pairs);
                }
            }
        }
    }
    for (mod.ports) |p| {
        if (p.direction == .output) continue;
        for (p.bits, 0..) |b, lane| {
            if (b != .sig) continue;
            try en.walkFrom(null, p.name, b.sig, lane, &pairs);
        }
    }

    var out: std.ArrayListUnmanaged(Crossing) = .empty;
    for (pairs.items) |pr| try out.append(alloc, try en.buildCrossing(pr, null));
    try en.appendBusGroups(&pairs, &out);
    std.mem.sort(Crossing, out.items, {}, struct {
        fn less(_: void, a: Crossing, b: Crossing) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.less);
    return .{ .backing = backing, .crossings = try out.toOwnedSlice(alloc) };
}

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
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

const Pair = struct {
    src_cell: ?usize,
    src_port: []const u8,
    src_bit: u32,
    src_lane: usize,
    dst_cell: usize,
    dst_pin: []const u8,
    dst_bit: u32,
    dst_lane: usize,
    dst_class: ?SinkClass,
    dst_control: bool,
    hops: []usize,
};

const ParentLink = struct { prev: ?u32, via: ?usize };

const Enumerator = struct {
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    alloc: std.mem.Allocator,
    clock_of: *const std.AutoHashMapUnmanaged(usize, clock.trace.Domain),
    bit_domains: *const std.AutoHashMapUnmanaged(u32, clock.trace.Domain),
    controls: []clock.trace.ControlPin,

    fn walkFrom(
        en: *Enumerator,
        src_cell: ?usize,
        src_port: []const u8,
        src_bit: u32,
        src_lane: usize,
        pairs: *std.ArrayListUnmanaged(Pair),
    ) error{OutOfMemory}!void {
        var seen = std.AutoHashMapUnmanaged(u32, ParentLink){};
        var queue: std.ArrayListUnmanaged(u32) = .empty;
        var head: usize = 0;
        try seen.put(en.alloc, src_bit, .{ .prev = null, .via = null });
        try queue.append(en.alloc, src_bit);
        while (head < queue.items.len) {
            const b = queue.items[head];
            head += 1;
            const loads = en.mod.loads_of.get(b) orelse continue;
            for (loads.items) |loc| {
                const ci = loc.cell orelse continue;
                const c = en.mod.cells[ci];
                if (isOpaqueMem(c.type)) continue;
                if (c.blackbox) continue;
                // Control arrivals emit, then keep walking: the value
                // still reaches the clock, so the glitch path survives.
                if (en.isControlSink(ci, loc.port)) {
                    try en.emit(pairs, src_cell, src_port, src_bit, src_lane, ci, loc.port, b, null, true, &seen);
                }
                if (sinkClass(c.type, loc.port)) |cls| {
                    // Same-cell pairs are self-feedback, never
                    // crossings: a flop's Q reaching its own D
                    // through comb is a counter, not a CDC.
                    if (src_cell != null and src_cell.? == ci) continue;
                    try en.emit(pairs, src_cell, src_port, src_bit, src_lane, ci, loc.port, b, cls, false, &seen);
                } else if (clock.cells.isSequential(c.type) or clock.cells.isMemoryClock(c.type)) {
                    // Unclassified sequential inputs end the walk:
                    // boundaries cut, never go transparent.
                    continue;
                } else {
                    try en.propagate(ci, c, loc.port, b, &seen, &queue);
                }
            }
        }
    }

    // Control pins are few (clock-path muxes and gates), so a
    // linear scan beats a map build in both code and cycles.
    fn isControlSink(en: *Enumerator, ci: usize, pin: []const u8) bool {
        for (en.controls) |cp| {
            if (cp.cell == ci and std.mem.eql(u8, cp.pin, pin)) return true;
        }
        return false;
    }

    fn emit(
        en: *Enumerator,
        pairs: *std.ArrayListUnmanaged(Pair),
        src_cell: ?usize,
        src_port: []const u8,
        src_bit: u32,
        src_lane: usize,
        ci: usize,
        pin: []const u8,
        b: u32,
        cls: ?SinkClass,
        control: bool,
        seen: *const std.AutoHashMapUnmanaged(u32, ParentLink),
    ) error{OutOfMemory}!void {
        try pairs.append(en.alloc, .{
            .src_cell = src_cell,
            .src_port = src_port,
            .src_bit = src_bit,
            .src_lane = src_lane,
            .dst_cell = ci,
            .dst_pin = pin,
            .dst_bit = b,
            .dst_lane = laneOf(en.mod.cells[ci], pin, b),
            .dst_class = cls,
            .dst_control = control,
            .hops = try en.reconstruct(seen, b),
        });
    }

    // Bitwise cells propagate lane-to-lane; fully connected would
    // invent crossings across wide buses. Reductions stay connected.
    fn propagate(
        en: *Enumerator,
        ci: usize,
        c: ir.types.Cell,
        pin: []const u8,
        bit: u32,
        seen: *std.AutoHashMapUnmanaged(u32, ParentLink),
        queue: *std.ArrayListUnmanaged(u32),
    ) error{OutOfMemory}!void {
        const lane = laneOf(c, pin, bit);
        for (c.ports) |p| {
            if (p.direction != .output or p.bits.len == 0) continue;
            if (outLane(c, pin, lane, p.bits.len)) |ol| {
                try en.visitBit(p.bits[ol], bit, ci, seen, queue);
            } else {
                for (p.bits) |ob| try en.visitBit(ob, bit, ci, seen, queue);
            }
        }
    }

    fn visitBit(
        en: *Enumerator,
        ob: ir.bits.Bit,
        from: u32,
        via: usize,
        seen: *std.AutoHashMapUnmanaged(u32, ParentLink),
        queue: *std.ArrayListUnmanaged(u32),
    ) error{OutOfMemory}!void {
        if (ob != .sig) return;
        if (seen.contains(ob.sig)) return;
        try seen.put(en.alloc, ob.sig, .{ .prev = from, .via = via });
        try queue.append(en.alloc, ob.sig);
    }

    fn reconstruct(en: *Enumerator, seen: *const std.AutoHashMapUnmanaged(u32, ParentLink), dst: u32) error{OutOfMemory}![]usize {
        var rev: std.ArrayListUnmanaged(usize) = .empty;
        var cur: ?u32 = dst;
        while (cur) |b| {
            const link = seen.get(b) orelse break;
            if (link.via) |ci| try rev.append(en.alloc, ci);
            cur = link.prev;
        }
        std.mem.reverse(usize, rev.items);
        return rev.toOwnedSlice(en.alloc);
    }

    fn buildCrossing(en: *Enumerator, pr: Pair, kind_override: ?Kind) error{OutOfMemory}!Crossing {
        const kind: Kind = kind_override orelse if (pr.dst_control)
            .clock_control
        else if (pr.dst_class == .clk)
            .clock_sink
        else if (pr.src_cell == null)
            if (en.typedClock(pr.src_port)) |_| .port_flop else .port_flop_untyped
        else
            // Blackbox outputs ride flop-flop-bit: the endpoint
            // cell type identifies them, and rules check it.
            .flop_flop_bit;
        const src_clk = try en.srcClock(pr);
        const dst_clk = try en.dstClock(pr);
        const src_name = try renderEndpoint(en.alloc, en.mod, pr.src_cell, pr.src_port, pr.src_bit);
        defer en.alloc.free(src_name);
        const dst_name = try renderEndpoint(en.alloc, en.mod, pr.dst_cell, pr.dst_pin, pr.dst_bit);
        defer en.alloc.free(dst_name);
        const ident = id.compute(@tagName(kind), src_name, dst_name, src_clk, dst_clk);
        const dc = en.mod.cells[pr.dst_cell];
        return .{
            .id = try en.alloc.dupe(u8, &ident),
            .kind = kind,
            .src = .{
                .cell = pr.src_cell,
                .port = try en.alloc.dupe(u8, pr.src_port),
                .bit = pr.src_bit,
                .lane = pr.src_lane,
            },
            .dst = .{
                .cell = pr.dst_cell,
                .port = try en.alloc.dupe(u8, pr.dst_pin),
                .bit = pr.dst_bit,
                .lane = pr.dst_lane,
            },
            .src_clk = src_clk,
            .dst_clk = dst_clk,
            .async_per_sdc = en.asyncFor(pr),
            .hops = pr.hops,
            .lanes = &.{},
            .instance_path = try en.dupePath(dc),
            .src_loc = try en.cellLoc(pr.src_cell),
            .dst_loc = try en.cellLoc(pr.dst_cell),
        };
    }

    // Bus groups cut from key-sorted runs: flop-source pairs
    // sharing (src cell+pin, dst cell+pin) gain one bus record
    // beside their bit records. Ports never group (src-reg only).
    fn appendBusGroups(
        en: *Enumerator,
        pairs: *const std.ArrayListUnmanaged(Pair),
        out: *std.ArrayListUnmanaged(Crossing),
    ) error{OutOfMemory}!void {
        var cand: std.ArrayListUnmanaged(usize) = .empty;
        for (pairs.items, 0..) |pr, i| {
            const sc = pr.src_cell orelse continue;
            if (en.mod.cells[sc].blackbox) continue;
            if (pr.dst_control or pr.dst_class == .clk) continue;
            try cand.append(en.alloc, i);
        }
        std.mem.sort(usize, cand.items, pairs, struct {
            fn less(ps: *const std.ArrayListUnmanaged(Pair), a: usize, b: usize) bool {
                const pa = ps.items[a];
                const pb = ps.items[b];
                if (pa.src_cell.? != pb.src_cell.?) return pa.src_cell.? < pb.src_cell.?;
                if (!std.mem.eql(u8, pa.src_port, pb.src_port)) return std.mem.lessThan(u8, pa.src_port, pb.src_port);
                if (pa.dst_cell != pb.dst_cell) return pa.dst_cell < pb.dst_cell;
                return std.mem.lessThan(u8, pa.dst_pin, pb.dst_pin);
            }
        }.less);
        var i: usize = 0;
        while (i < cand.items.len) {
            var j = i + 1;
            while (j < cand.items.len and sameBusKey(pairs.items[cand.items[i]], pairs.items[cand.items[j]])) : (j += 1) {}
            if (j - i >= 2) {
                const run = cand.items[i..j];
                std.mem.sort(usize, run, pairs, struct {
                    fn less(ps: *const std.ArrayListUnmanaged(Pair), a: usize, b: usize) bool {
                        const pa = ps.items[a];
                        const pb = ps.items[b];
                        if (pa.src_lane != pb.src_lane) return pa.src_lane < pb.src_lane;
                        return pa.dst_lane < pb.dst_lane;
                    }
                }.less);
                const lanes = try en.alloc.alloc(Lane, run.len);
                for (run, 0..) |k, n| {
                    lanes[n] = .{ .src_lane = pairs.items[k].src_lane, .dst_lane = pairs.items[k].dst_lane };
                }
                var bus = try en.buildCrossing(pairs.items[run[0]], .flop_flop_bus);
                bus.lanes = lanes;
                bus.hops = try en.alloc.dupe(usize, bus.hops);
                try out.append(en.alloc, bus);
            }
            i = j;
        }
    }

    fn typedClock(en: *Enumerator, port: []const u8) ?[]const u8 {
        return sdc.model.portClock(en.model, port);
    }

    // Data typing first, clock roots second: a clock port driving
    // data (or a clock) resolves to its declared clock, not a
    // synthetic domain, while CDC-011 still keys on typing alone.
    fn srcClockName(en: *Enumerator, port: []const u8) ?[]const u8 {
        if (sdc.model.portClock(en.model, port)) |c| return c;
        return sdc.model.rootClock(en.model, port);
    }

    // Destination domains come from the flop table, the memory
    // clock, or the controlled output — never guessed.
    fn dstDomain(en: *Enumerator, pr: Pair) ?clock.trace.Domain {
        if (pr.dst_control) return en.controlOutDomain(pr.dst_cell);
        if (clock.cells.isMemoryClock(en.mod.cells[pr.dst_cell].type)) return en.memClockDomain(pr.dst_cell);
        return en.clock_of.get(pr.dst_cell);
    }

    fn srcDomain(en: *Enumerator, pr: Pair) ?clock.trace.Domain {
        const ci = pr.src_cell orelse return null;
        if (en.mod.cells[ci].blackbox) return null;
        if (clock.cells.isMemRead(en.mod.cells[ci].type)) {
            if (!readEnabled(en.mod.cells[ci])) return null;
            return en.memClockDomain(ci);
        }
        return en.clock_of.get(ci);
    }

    // The controlled clock: the domain leaving the mux or gate output.
    fn controlOutDomain(en: *Enumerator, ci: usize) ?clock.trace.Domain {
        const y = portBits(en.mod.cells[ci], "Y") orelse return null;
        for (y) |b| {
            if (b != .sig) continue;
            if (en.bit_domains.get(b.sig)) |d| return d;
        }
        return null;
    }

    fn memClockDomain(en: *Enumerator, ci: usize) ?clock.trace.Domain {
        const clk = portBits(en.mod.cells[ci], "CLK") orelse return null;
        for (clk) |b| {
            if (b != .sig) continue;
            if (en.bit_domains.get(b.sig)) |d| return d;
        }
        return null;
    }

    fn srcClock(en: *Enumerator, pr: Pair) error{OutOfMemory}![]const u8 {
        if (pr.src_cell != null) {
            if (en.srcDomain(pr)) |d| return en.alloc.dupe(u8, d.name);
            return en.alloc.dupe(u8, "unknown");
        }
        if (en.srcClockName(pr.src_port)) |c| return en.alloc.dupe(u8, c);
        return std.fmt.allocPrint(en.alloc, "port:{s}", .{pr.src_port});
    }

    fn dstClock(en: *Enumerator, pr: Pair) error{OutOfMemory}![]const u8 {
        if (en.dstDomain(pr)) |d| return en.alloc.dupe(u8, d.name);
        return en.alloc.dupe(u8, "unknown");
    }

    // Async when any leg pair is async: a muxed clock is only as
    // synchronous as its least synchronous leg. Unknown forces true.
    fn asyncFor(en: *Enumerator, pr: Pair) bool {
        const dst = en.dstDomain(pr) orelse return true;
        if (std.mem.eql(u8, dst.name, "unknown")) return true;
        if (pr.src_cell != null) {
            const src = en.srcDomain(pr) orelse return true;
            if (std.mem.eql(u8, src.name, "unknown")) return true;
            for (src.legs) |sl| {
                for (dst.legs) |dl| {
                    if (en.model.areAsync(sl, dl)) return true;
                }
            }
            return false;
        }
        const src_name = en.srcClockName(pr.src_port) orelse return true;
        for (dst.legs) |dl| {
            if (en.model.areAsync(src_name, dl)) return true;
        }
        return false;
    }

    fn dupePath(en: *Enumerator, c: ir.types.Cell) error{OutOfMemory}![][]const u8 {
        const out = try en.alloc.alloc([]const u8, c.instance_path.len);
        for (c.instance_path, 0..) |seg, i| out[i] = try en.alloc.dupe(u8, seg);
        return out;
    }

    fn cellLoc(en: *Enumerator, ci: ?usize) error{OutOfMemory}![]const u8 {
        const c = ci orelse return en.alloc.dupe(u8, "");
        return en.alloc.dupe(u8, en.mod.cells[c].src orelse "");
    }
};

// One rendering shared by ID hashing and CLI display, so the
// printed endpoints always match what the ID was hashed over.
pub fn renderEndpoint(alloc: std.mem.Allocator, mod: *const ir.types.Module, cell: ?usize, port: []const u8, bit: u32) error{OutOfMemory}![]const u8 {
    if (cell) |ci| {
        return std.fmt.allocPrint(alloc, "c:{s}:{s}:{d}", .{ mod.cells[ci].name, port, bit });
    }
    return std.fmt.allocPrint(alloc, "p:{s}:{d}", .{ port, bit });
}

// Async reads (CLK_ENABLE off or absent) leave data outside every
// clock: unknown source, conservative async. Absent is not sync.
fn readEnabled(c: ir.types.Cell) bool {
    for (c.params) |p| {
        if (!std.mem.eql(u8, p.name, "CLK_ENABLE")) continue;
        switch (p.value) {
            .int => |i| return i == 1,
            .str => |s| return s.len > 0 and s[s.len - 1] == '1',
        }
    }
    return false;
}

// Lane-parallel output for an arrival lane, or null to fan out.
// $pmux option legs wrap lane-modulo across the output width.
fn outLane(c: ir.types.Cell, pin: []const u8, lane: usize, out_len: usize) ?usize {
    if (isControlPin(c.type, pin)) return null;
    if (!laneParallel(c.type)) return null;
    if (std.mem.eql(u8, c.type, "$pmux") and std.mem.eql(u8, pin, "B")) return lane % out_len;
    if (lane < out_len) return lane;
    return null;
}

fn laneParallel(cell_type: []const u8) bool {
    for ([_][]const u8{ "$not", "$and", "$or", "$xor", "$xnor", "$mux", "$pmux", "$ternary", "$bwmux", "$tribuf" }) |t| {
        if (std.mem.eql(u8, cell_type, t)) return true;
    }
    return false;
}

fn sameBusKey(a: Pair, b: Pair) bool {
    return a.src_cell.? == b.src_cell.? and std.mem.eql(u8, a.src_port, b.src_port) and
        a.dst_cell == b.dst_cell and std.mem.eql(u8, a.dst_pin, b.dst_pin);
}

fn laneOf(c: ir.types.Cell, pin: []const u8, bit: u32) usize {
    if (portBits(c, pin)) |list| {
        for (list, 0..) |b, i| {
            if (b == .sig and b.sig == bit) return i;
        }
    }
    return 0;
}
