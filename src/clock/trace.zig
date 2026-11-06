const std = @import("std");
const cells = @import("cells.zig");
const ir = @import("../ir.zig");
const sdc = @import("../sdc.zig");

pub const Domain = struct {
    name: []const u8,
    root: []const u8,
    notes: [][]const u8,
    // Member clocks: one for plain domains, several for muxed
    // unions. Rules iterate legs instead of parsing names.
    legs: [][]const u8,
    // Top-mux side per leg, parallel to legs; side 255 reads
    // unconditional (the leg arrives under every top side).
    // Empty exactly when the domain is plain.
    sels: []LegSel,
    // Every mux cell outward, top first, deduplicated. Longer
    // than one means nested unions whose deeper sides merged
    // away: conditions below the top stay unrecorded.
    muxes: []usize,
};

// One leg's top-mux condition: which mux, and which side takes
// it ($mux A/B as 0/1, OR-mux AND position). Two legs sharing
// a $mux with sides 0 and 1 never co-occur; anything else may.
// The role fields split by mux kind: $mux legs carry the select
// domain, OR-mux legs the AND gate with its clock bit (the rest
// are enables); the tracer knows both, and rules cannot re-derive
// the AND's clock leg soundly after the fact.
pub const LegSel = struct {
    mux: usize,
    side: u8,
    gate: ?GateRef,
    sel_dom: []const u8,
};

// OR-mux AND cell plus the clock input bit it was validated
// with: every other input bit is one of the leg's enables.
pub const GateRef = struct {
    cell: usize,
    pin: []const u8,
    bit: u32,
};

pub const both_sides: u8 = 255;

// Sort key while a union assembles: one leg, one top side,
// one gate. Runs keep the first gate: a leg under several
// ANDs is redundant muxing, and the first enables stand in.
const LegSide = struct { leg: []const u8, side: u8, gate: ?GateRef };

pub const FlopDomain = struct {
    cell: usize,
    domain: Domain,
};

// A clock-network control pin and the domain feeding it: CDC-010
// compares this against the clock legs it switches or gates.
pub const ControlPin = struct {
    cell: usize,
    pin: []const u8,
    domain: Domain,
};

// A declared clock root resolved to one bit: the clock it
// defines, the concrete object name matched, and the pattern
// that claimed it (same-pattern namespaces never conflict).
pub const Root = struct {
    clock: []const u8,
    name: []const u8,
    pat: []const u8,
};

pub const Assignment = struct {
    // Heap-owned, matching Module: copying a live arena orphans
    // later allocations from deinit (see ir/types.zig).
    backing: *std.heap.ArenaAllocator,
    flops: []FlopDomain,
    controls: []ControlPin,
    // Every bit resolved while tracing, kept for consumers that
    // need domains below flop granularity (crossing endpoints).
    bit_domains: std.AutoHashMapUnmanaged(u32, Domain),
    // Clock-combine declines, sorted by cell: CDC-023 reports
    // these instead of re-walking the tracer's own decision.
    combines: []Combine,

    pub fn deinit(self: *Assignment) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }
};

// A gate whose legs carried two or more distinct declared
// clocks: the output bit, its driver, and the leg clocks.
pub const Combine = struct {
    cell: usize,
    bit: u32,
    clocks: [][]const u8,
};

// One backward walk per CLK bit with a shared memo: each bit
// resolves once, so tracing stays linear in design size.
pub fn assign(parent: std.mem.Allocator, mod: *const ir.types.Module, model: *const sdc.model.Model, warnings: *std.ArrayListUnmanaged(sdc.tokens.Warning)) error{OutOfMemory}!Assignment {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();

    var roots = try resolveRoots(alloc, mod, model, warnings);
    var memo = std.AutoHashMapUnmanaged(u32, Domain){};
    var active = std.AutoHashMapUnmanaged(u32, void){};
    var flops: std.ArrayListUnmanaged(FlopDomain) = .empty;
    var controls: std.ArrayListUnmanaged(ControlPin) = .empty;
    var combine_sets = std.AutoHashMapUnmanaged(u32, std.StringHashMapUnmanaged(void)){};
    var w = Walker{ .mod = mod, .model = model, .alloc = alloc, .memo = &memo, .active = &active, .controls = &controls, .combines = &combine_sets, .roots = &roots };
    for (mod.cells, 0..) |c, ci| {
        if (!cells.isSequential(c.type)) continue;
        const dom = if (clkBits(c)) |clk|
            if (cells.isLatch(c.type)) try w.resolveLatch(clk) else try w.resolveBits(clk)
        else
            try w.make("unknown", "", &.{"no clock pin"});
        try flops.append(alloc, .{ .cell = ci, .domain = dom });
    }
    // Memory clocks resolve into the memo without records: crossing
    // enumeration reads them for memory endpoint domains.
    for (mod.cells) |c| {
        if (!cells.isMemoryClock(c.type)) continue;
        if (clkBits(c)) |clk| {
            _ = try w.resolveBits(clk);
        }
    }
    var combines = std.ArrayListUnmanaged(Combine).empty;
    var cit = combine_sets.iterator();
    while (cit.next()) |ce| {
        const drv = mod.driver_of.get(ce.key_ptr.*) orelse continue;
        const ci = drv.cell orelse continue;
        var names = std.ArrayListUnmanaged([]const u8).empty;
        var nit = ce.value_ptr.iterator();
        while (nit.next()) |ne| try names.append(alloc, ne.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        try combines.append(alloc, .{ .cell = ci, .bit = ce.key_ptr.*, .clocks = try names.toOwnedSlice(alloc) });
    }
    std.mem.sort(Combine, combines.items, mod, struct {
        fn less(m: *const ir.types.Module, a: Combine, b: Combine) bool {
            const ck = std.mem.order(u8, m.cells[a.cell].name, m.cells[b.cell].name);
            if (ck != .eq) return ck == .lt;
            return a.bit < b.bit;
        }
    }.less);
    return .{
        .backing = backing,
        .flops = try flops.toOwnedSlice(alloc),
        .controls = try controls.toOwnedSlice(alloc),
        .bit_domains = memo,
        .combines = try combines.toOwnedSlice(alloc),
    };
}

// Declared roots resolve once to bit sets: patterns match top
// ports, cell output pins as `cell/pin`, and netnames keys.
// Sorted patterns claim first-wins; overlaps and dead patterns
// warn instead of silently misrooting or degrading to async.
fn resolveRoots(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    warnings: *std.ArrayListUnmanaged(sdc.tokens.Warning),
) error{OutOfMemory}!std.AutoHashMapUnmanaged(u32, Root) {
    var roots = std.AutoHashMapUnmanaged(u32, Root){};
    var pats = std.ArrayListUnmanaged([]const u8).empty;
    var it = model.clock_roots.iterator();
    while (it.next()) |e| try pats.append(alloc, e.key_ptr.*);
    std.mem.sort([]const u8, pats.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (pats.items) |pat| {
        const clock = model.clock_roots.get(pat).?;
        var claimed: usize = 0;
        var overlaps: usize = 0;
        claimed += try claimPortBits(alloc, mod, &roots, pat, clock, &overlaps);
        claimed += try claimPinBits(alloc, mod, &roots, pat, clock, &overlaps);
        claimed += try claimNetBits(alloc, mod, &roots, pat, clock, &overlaps);
        // Overlap first: a pattern finding only owned bits
        // matched, it just lost every claim.
        if (overlaps > 0) {
            try warnings.append(alloc, .{ .line = 0, .text = try std.fmt.allocPrint(alloc, "clock root {s} overlaps {d} rooted bit{s}", .{ pat, overlaps, if (overlaps == 1) "" else "s" }) });
        } else if (claimed == 0) {
            try warnings.append(alloc, .{ .line = 0, .text = try std.fmt.allocPrint(alloc, "clock root unmatched: {s}", .{pat}) });
        }
    }
    return roots;
}

fn claimBit(
    alloc: std.mem.Allocator,
    roots: *std.AutoHashMapUnmanaged(u32, Root),
    bit: u32,
    clock: []const u8,
    name: []const u8,
    pat: []const u8,
    overlaps: *usize,
) error{OutOfMemory}!bool {
    if (roots.get(bit)) |r| {
        // One pattern across namespaces is agreement, not
        // conflict; only a second pattern overlaps.
        if (!std.mem.eql(u8, r.pat, pat)) overlaps.* += 1;
        return false;
    }
    try roots.put(alloc, bit, .{ .clock = clock, .name = name, .pat = pat });
    return true;
}

fn claimPortBits(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    roots: *std.AutoHashMapUnmanaged(u32, Root),
    pat: []const u8,
    clock: []const u8,
    overlaps: *usize,
) error{OutOfMemory}!usize {
    var n: usize = 0;
    for (mod.ports) |p| {
        if (p.direction == .output) continue;
        if (!sdc.model.matchGlob(pat, p.name)) continue;
        for (p.bits) |b| {
            if (b != .sig) continue;
            if (try claimBit(alloc, roots, b.sig, clock, p.name, pat, overlaps)) n += 1;
        }
    }
    return n;
}

fn claimPinBits(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    roots: *std.AutoHashMapUnmanaged(u32, Root),
    pat: []const u8,
    clock: []const u8,
    overlaps: *usize,
) error{OutOfMemory}!usize {
    const slash = std.mem.lastIndexOfScalar(u8, pat, '/') orelse return 0;
    const cellpat = pat[0..slash];
    const pinpat = pat[slash + 1 ..];
    var n: usize = 0;
    for (mod.cells) |c| {
        if (!sdc.model.matchGlob(cellpat, c.name)) continue;
        for (c.ports) |p| {
            if (p.direction != .output) continue;
            if (!sdc.model.matchGlob(pinpat, p.name)) continue;
            const name = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ c.name, p.name });
            for (p.bits) |b| {
                if (b != .sig) continue;
                if (try claimBit(alloc, roots, b.sig, clock, name, pat, overlaps)) n += 1;
            }
        }
    }
    return n;
}

fn claimNetBits(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    roots: *std.AutoHashMapUnmanaged(u32, Root),
    pat: []const u8,
    clock: []const u8,
    overlaps: *usize,
) error{OutOfMemory}!usize {
    var n: usize = 0;
    var it = mod.netnames.iterator();
    while (it.next()) |e| {
        if (!sdc.model.matchGlob(pat, e.key_ptr.*)) continue;
        for (e.value_ptr.bits) |b| {
            if (b != .sig) continue;
            if (try claimBit(alloc, roots, b.sig, clock, e.key_ptr.*, pat, overlaps)) n += 1;
        }
    }
    return n;
}

// Bitwise gates resolve per position: the output index picks
// the matching leg bit on every input port.
fn outBitIndex(c: ir.types.Cell, bit: u32) ?usize {
    for (c.ports) |p| {
        if (p.direction != .output) continue;
        for (p.bits, 0..) |b, i| {
            if (b == .sig and b.sig == bit) return i;
        }
    }
    return null;
}

// Back through buffers to a clock-gate $and, eight steps max:
// anything else driving the leg voids the mux shape.
fn gateLeg(mod: *const ir.types.Module, bit: u32) ?usize {
    var cur = bit;
    for (0..8) |_| {
        const drv = mod.driver_of.get(cur) orelse return null;
        const ci = drv.cell orelse return null;
        const c = mod.cells[ci];
        if (!std.mem.eql(u8, c.type, "$buf")) {
            if (!cells.isClockGate(c.type)) return null;
            return ci;
        }
        cur = transparentLane(c, cur) orelse return null;
    }
    return null;
}

// One step back through a buffer: the resolved bit's lane on
// the input side. Slang buffers every net, wide buses included,
// so single-bit stepping strands legs behind bus buffers.
fn transparentLane(c: ir.types.Cell, bit: u32) ?u32 {
    const lane = outBitIndex(c, bit) orelse return null;
    for (c.ports) |p| {
        if (p.direction == .output) continue;
        if (lane < p.bits.len and p.bits[lane] == .sig) return p.bits[lane].sig;
    }
    return null;
}

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
    }
    return null;
}

fn clkBits(c: ir.types.Cell) ?[]ir.bits.Bit {
    // Flops clock on CLK; latches open on G or EN instead.
    if (portBits(c, "CLK")) |b| return b;
    if (portBits(c, "G")) |b| return b;
    return portBits(c, "EN");
}

// Declared clocks and their unions identify a gate's clock
// leg; unknown and undeclared-port names never do. Unions
// must count: gates pass them and ORs flatten them, and
// excluding them strands every clock gated downstream of a
// mux, which on real trees is nearly every gated clock.
fn isClockDomain(name: []const u8) bool {
    if (std.mem.eql(u8, name, "unknown")) return false;
    if (std.mem.startsWith(u8, name, "port:")) return false;
    return true;
}

const Walker = struct {
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    alloc: std.mem.Allocator,
    memo: *std.AutoHashMapUnmanaged(u32, Domain),
    active: *std.AutoHashMapUnmanaged(u32, void),
    controls: *std.ArrayListUnmanaged(ControlPin),
    combines: *std.AutoHashMapUnmanaged(u32, std.StringHashMapUnmanaged(void)),
    roots: *const std.AutoHashMapUnmanaged(u32, Root),

    // A clock bus must agree with itself; disagreement is broken
    // input, reported as unknown rather than picked arbitrarily.
    fn resolveBits(w: *Walker, list: []const ir.bits.Bit) error{OutOfMemory}!Domain {
        var first: ?Domain = null;
        for (list) |b| {
            if (b != .sig) continue;
            const d = try w.resolveBit(b.sig);
            if (first == null) {
                first = d;
            } else if (!std.mem.eql(u8, first.?.name, d.name)) {
                return w.make("unknown", "", &.{"clock bits disagree"});
            }
        }
        return first orelse w.make("unknown", "", &.{"unconnected clock"});
    }

    fn resolveBit(w: *Walker, bit: u32) error{OutOfMemory}!Domain {
        if (w.memo.get(bit)) |d| return d;
        // Active marks the current descent: revisiting one means a
        // combinational loop, which has no meaningful domain.
        if (w.active.contains(bit)) return w.make("unknown", "", &.{"clock-path loop"});
        // A declared root defines the clock at its bit: descent
        // stops here, past oscillator rings and analog bounds.
        // Memoized like every exit: memory endpoints read roots
        // back out of the memo, never re-walking to them.
        if (w.roots.get(bit)) |r| {
            const dom = try w.make(r.clock, r.name, &.{});
            try w.memo.put(w.alloc, bit, dom);
            return dom;
        }
        const drv = w.mod.driver_of.get(bit) orelse return w.make("unknown", "", &.{"undriven clock"});
        try w.active.put(w.alloc, bit, {});
        const dom = if (drv.cell) |ci| try w.throughCell(bit, ci) else try w.throughPort(drv.port);
        _ = w.active.remove(bit);
        try w.memo.put(w.alloc, bit, dom);
        return dom;
    }

    // Latch enables are data, not clocks: a typed enable borrows
    // its input-delay clock, so same-domain latches stay silent.
    // Flop CLKs never take this path; undeclared clock roots are
    // CDC-021's finding, not a typing to paper over.
    fn resolveLatch(w: *Walker, en: []const ir.bits.Bit) error{OutOfMemory}!Domain {
        const dom = try w.resolveBits(en);
        if (!std.mem.startsWith(u8, dom.name, "port:")) return dom;
        if (sdc.model.portClock(w.model, dom.root)) |c| return w.make(c, c, &.{});
        return dom;
    }

    fn throughPort(w: *Walker, port: []const u8) error{OutOfMemory}!Domain {
        // Declared roots resolve up front (resolveRoots); only the
        // same-name clock fallback still lives at trace time.
        if (w.model.clocks.contains(port)) return w.make(port, port, &.{});
        // Undeclared roots still get a domain: downstream analysis
        // continues, and CDC-021 judges the missing declaration.
        const owned = try std.fmt.allocPrint(w.alloc, "port:{s}", .{port});
        const legs = try w.alloc.alloc([]const u8, 1);
        legs[0] = owned;
        return .{
            .name = owned,
            .root = try w.alloc.dupe(u8, port),
            .notes = try w.dupeNotes(&.{"undeclared clock root"}),
            .legs = legs,
            .sels = &.{},
            .muxes = &.{},
        };
    }

    fn throughCell(w: *Walker, bit: u32, ci: usize) error{OutOfMemory}!Domain {
        const c = w.mod.cells[ci];
        if (cells.isTransparent(c.type)) return w.throughTransparent(bit, c);
        if (cells.isClockMux(c.type)) return w.throughMux(ci);
        if (cells.isClockGate(c.type)) return w.throughGate(bit, ci);
        if (std.mem.eql(u8, c.type, "$or") or std.mem.eql(u8, c.type, "$logic_or")) return w.throughOrMux(bit, ci);
        if (cells.isSequential(c.type)) return w.throughSequential(ci);
        if (c.blackbox) return w.make("unknown", "", &.{"blackbox-driven clock"});
        return w.unhandled(c);
    }

    // Transparent cells pass the domain through; only inverters
    // earn the note, so buffers stay silent on clock paths.
    // Lane-following: wide buffers carry whole buses, so only
    // the resolved bit's lane continues the clock. Agreeing
    // across lanes misroots const-tied lanes to their neighbor.
    fn throughTransparent(w: *Walker, bit: u32, c: ir.types.Cell) error{OutOfMemory}!Domain {
        const lane = outBitIndex(c, bit);
        var inputs: std.ArrayListUnmanaged(ir.bits.Bit) = .empty;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            if (lane) |l| {
                if (l < p.bits.len) try inputs.append(w.alloc, p.bits[l]);
            } else {
                for (p.bits) |b| try inputs.append(w.alloc, b);
            }
        }
        const dom = try w.resolveBits(inputs.items);
        if (std.mem.eql(u8, dom.name, "unknown")) return dom;
        if (!cells.isInverting(c.type)) return dom;
        return w.withNote(dom, "inverted clock");
    }

    fn throughMux(w: *Walker, ci: usize) error{OutOfMemory}!Domain {
        const c = w.mod.cells[ci];
        const a = portBits(c, "A") orelse return w.make("unknown", "", &.{"malformed clock mux"});
        const b = portBits(c, "B") orelse return w.make("unknown", "", &.{"malformed clock mux"});
        const s = portBits(c, "S") orelse return w.make("unknown", "", &.{"malformed clock mux"});
        if (constSel(s)) |sel| {
            const dom = try w.resolveBits(if (sel) b else a);
            if (std.mem.eql(u8, dom.name, "unknown"))
                return w.make("unknown", "", &.{"clock mux static leg unresolved"});
            return w.withNote(dom, if (sel) "clock mux static select B" else "clock mux static select A");
        }
        // Dynamic selects are recorded before legs resolve: the
        // select domain stands even when a leg does not.
        const sel = try w.resolveBits(s);
        try w.recordControl(ci, "S", sel);
        const da = try w.resolveBits(a);
        const db = try w.resolveBits(b);
        if (std.mem.eql(u8, da.name, "unknown") or std.mem.eql(u8, db.name, "unknown"))
            return w.make("unknown", "", &.{"clock mux unresolved leg"});
        var all: std.ArrayListUnmanaged(LegSide) = .empty;
        for (da.legs) |l| try all.append(w.alloc, .{ .leg = l, .side = 0, .gate = null });
        for (db.legs) |l| try all.append(w.alloc, .{ .leg = l, .side = 1, .gate = null });
        const n = dedupeLegs(all.items);
        const sel_desc = try w.describeSelect(s);
        defer w.alloc.free(sel_desc);
        const note = try std.fmt.allocPrint(w.alloc, "clock mux select: {s}", .{sel_desc});
        defer w.alloc.free(note);
        if (n == 1) return w.withNote(da, note);
        const legs = try w.alloc.alloc([]const u8, n);
        const sels = try w.alloc.alloc(LegSel, n);
        const sel_dom = try w.alloc.dupe(u8, sel.name);
        for (all.items[0..n], 0..) |ls, i| {
            legs[i] = ls.leg;
            sels[i] = .{ .mux = ci, .side = ls.side, .gate = ls.gate, .sel_dom = sel_dom };
        }
        const muxes = try w.joinMuxes(ci, &.{ da.muxes, db.muxes });
        const root = try std.fmt.allocPrint(w.alloc, "mux:{s}", .{c.name});
        defer w.alloc.free(root);
        return w.makeUnion(legs, sels, muxes, root, note);
    }

    // Sort by leg, collapse runs: a leg under several sides reads
    // unconditional (255); single-side legs keep their side.
    // Returns the distinct count; the head holds the result.
    fn dedupeLegs(items: []LegSide) usize {
        std.mem.sort(LegSide, items, {}, struct {
            fn less(_: void, x: LegSide, y: LegSide) bool {
                return std.mem.lessThan(u8, x.leg, y.leg);
            }
        }.less);
        var n: usize = 0;
        var i: usize = 0;
        while (i < items.len) {
            var side = items[i].side;
            var j = i + 1;
            while (j < items.len and std.mem.eql(u8, items[j].leg, items[i].leg)) : (j += 1) {
                if (items[j].side != side) side = both_sides;
            }
            items[n] = .{ .leg = items[i].leg, .side = side, .gate = items[i].gate };
            n += 1;
            i = j;
        }
        return n;
    }

    // Top mux first, then each nested path in order, duplicates
    // dropped: short lists, so the scan stays trivial.
    fn joinMuxes(w: *Walker, ci: usize, rest: []const []const usize) error{OutOfMemory}![]usize {
        var out = std.ArrayListUnmanaged(usize).empty;
        try out.append(w.alloc, ci);
        for (rest) |r| {
            for (r) |m| {
                var seen = false;
                for (out.items) |o| {
                    if (o == m) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try out.append(w.alloc, m);
            }
        }
        return out.toOwnedSlice(w.alloc);
    }

    // OR-combined clocks union: every leg must resolve to a
    // clock, gated or not. AND-gated legs (a glitch-free mux's
    // output stage) keep their selects; legs arriving any other
    // way degrade the union to sel-less rather than unknown —
    // an OR of clocks carries every leg's edges either way.
    fn throughOrMux(w: *Walker, bit: u32, ci: usize) error{OutOfMemory}!Domain {
        const c = w.mod.cells[ci];
        const idx = outBitIndex(c, bit) orelse return w.unhandled(c);
        var first: ?Domain = null;
        var all: std.ArrayListUnmanaged(LegSide) = .empty;
        var nests: std.ArrayListUnmanaged([]const usize) = .empty;
        var side: usize = 0;
        // $or legs arrive one per input port; $logic_or packs N
        // legs in one port. One bit list either way: each bit a leg.
        var leg_bits: std.ArrayListUnmanaged(u32) = .empty;
        const wide = std.mem.eql(u8, c.type, "$logic_or");
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            if (wide) {
                for (p.bits) |wb| {
                    if (wb != .sig) return w.unhandled(c);
                    try leg_bits.append(w.alloc, wb.sig);
                }
            } else {
                if (idx >= p.bits.len) return w.unhandled(c);
                const b = p.bits[idx];
                if (b != .sig) return w.unhandled(c);
                try leg_bits.append(w.alloc, b.sig);
            }
        }
        var all_gated = true;
        for (leg_bits.items) |lb| {
            const d = try w.resolveBit(lb);
            if (!isClockDomain(d.name)) return w.unhandled(c);
            if (first == null) first = d;
            std.debug.assert(side < both_sides);
            // A found gate must validate: an AND the leg resolves
            // through that clocks nothing is corrupt, not plain.
            var gate: ?GateRef = null;
            if (gateLeg(w.mod, lb)) |and_ci| {
                if (try w.clockLegs(and_ci) != 1) return w.unhandled(c);
                gate = try w.clockInput(and_ci);
            } else all_gated = false;
            for (d.legs) |l| try all.append(w.alloc, .{ .leg = l, .side = @intCast(side), .gate = gate });
            try nests.append(w.alloc, d.muxes);
            side += 1;
        }
        if (first == null) return w.unhandled(c);
        const n = dedupeLegs(all.items);
        const note = if (all_gated) "or-built clock mux" else "or-combined clocks";
        if (n == 1) return w.withNote(first.?, note);
        const legs = try w.alloc.alloc([]const u8, n);
        // Selects only mean as a complete exclusive set; one
        // ungated leg voids all of them, not just its own.
        const sels = try w.alloc.alloc(LegSel, if (all_gated) n else 0);
        if (all_gated) {
            for (all.items[0..n], 0..) |ls, i| {
                legs[i] = ls.leg;
                sels[i] = .{ .mux = ci, .side = ls.side, .gate = ls.gate, .sel_dom = &.{} };
            }
        } else {
            for (all.items[0..n], 0..) |ls, i| legs[i] = ls.leg;
        }
        const muxes = try w.joinMuxes(ci, nests.items);
        const root = try std.fmt.allocPrint(w.alloc, "ormux:{s}", .{c.name});
        defer w.alloc.free(root);
        return w.makeUnion(legs, sels, muxes, root, note);
    }

    fn unhandled(w: *Walker, c: ir.types.Cell) error{OutOfMemory}!Domain {
        const why = try std.fmt.allocPrint(w.alloc, "unhandled {s} on clock path", .{c.type});
        defer w.alloc.free(why);
        return w.make("unknown", "", &.{why});
    }

    // The clock input of a validated single-clock gate: pin and
    // bit, so the union records which input carries the leg and
    // rules read the rest as enables. Flop-driven legs lose the
    // tie: an enable latch reports its master's domain, so the
    // first clock leg found is often the enable, not the clock.
    fn clockInput(w: *Walker, ci: usize) error{OutOfMemory}!?GateRef {
        const c = w.mod.cells[ci];
        var fallback: ?GateRef = null;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b != .sig) continue;
                const d = try w.resolveBit(b.sig);
                if (!isClockDomain(d.name)) continue;
                const ref = GateRef{
                    .cell = ci,
                    .pin = try w.alloc.dupe(u8, p.name),
                    .bit = b.sig,
                };
                if (!w.drivenByFlop(b.sig)) return ref;
                if (fallback == null) fallback = ref;
            }
        }
        return fallback;
    }

    // Distinct clock domains on a gate's legs, flop-driven
    // legs excluded: they are enables (see throughGate), and
    // counting them forges second legs the gate itself rejects.
    fn clockLegs(w: *Walker, ci: usize) error{OutOfMemory}!usize {
        const c = w.mod.cells[ci];
        var names = std.StringHashMapUnmanaged(void).empty;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b != .sig) continue;
                const d = try w.resolveBit(b.sig);
                if (isClockDomain(d.name) and w.countAsClock(b.sig)) try names.put(w.alloc, d.name, {});
            }
        }
        return names.count();
    }

    // A clock gate passes its clock leg and notes the rest as
    // enables; ambiguous legs stay unknown rather than guessed.
    // Flop-driven legs are enables unless declared or toggling
    // (see countAsClock): an enable flop reports its own domain,
    // which otherwise forges a second clock leg on every gate.
    fn throughGate(w: *Walker, bit: u32, ci: usize) error{OutOfMemory}!Domain {
        const c = w.mod.cells[ci];
        var clock_dom: ?Domain = null;
        var clock_legs = std.StringHashMapUnmanaged(void).empty;
        var enables: std.ArrayListUnmanaged([]const u8) = .empty;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b != .sig) continue;
                const d = try w.resolveBit(b.sig);
                if (isClockDomain(d.name) and w.countAsClock(b.sig)) {
                    try clock_legs.put(w.alloc, d.name, {});
                    if (clock_dom == null) clock_dom = d;
                } else {
                    const desc = try w.describeBit(b);
                    var seen = false;
                    for (enables.items) |e| if (std.mem.eql(u8, e, desc)) {
                        seen = true;
                        break;
                    };
                    if (seen) {
                        w.alloc.free(desc);
                    } else {
                        try enables.append(w.alloc, desc);
                    }
                }
            }
        }
        // Every leg resolves before the decline: nested combines
        // and controls below the gate still get recorded.
        if (clock_legs.count() >= 2) {
            const slot = try w.combines.getOrPut(w.alloc, bit);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            var lit = clock_legs.iterator();
            while (lit.next()) |le| try slot.value_ptr.put(w.alloc, le.key_ptr.*, {});
            return w.make("unknown", "", &.{"clock gate with multiple clock legs"});
        }
        var dom = clock_dom orelse return w.make("unknown", "", &.{"clock gate without clock leg"});
        // Every non-clock leg is a recorded enable; flop-driven
        // legs join them even on agreement (see drivenByFlop).
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b != .sig) continue;
                const d = try w.resolveBit(b.sig);
                if (!std.mem.eql(u8, d.name, dom.name) or w.drivenByFlop(b.sig)) {
                    try w.recordControl(ci, p.name, d);
                }
            }
        }
        if (enables.items.len == 0) return w.withNote(dom, "clock gate");
        for (enables.items) |e| {
            const note = try std.fmt.allocPrint(w.alloc, "clock gate enable: {s}", .{e});
            defer w.alloc.free(note);
            dom = try w.withNote(dom, note);
        }
        return dom;
    }

    // A flop driving a clock is a divider until proven otherwise:
    // keep its own (master) domain and flag the unmodeled division.
    fn throughSequential(w: *Walker, ci: usize) error{OutOfMemory}!Domain {
        const c = w.mod.cells[ci];
        const clk = clkBits(c) orelse return w.make("unknown", "", &.{"divider without clock"});
        const master = try w.resolveBits(clk);
        if (std.mem.eql(u8, master.name, "unknown"))
            return w.make("unknown", "", &.{"divider with unknown master"});
        if (w.isToggle(ci)) return w.withNote(master, "divide-by-2, master kept");
        return w.withNote(master, "unrecognized divider, master kept");
    }

    // Single-bit flop whose D folds back to its own Q through at
    // most transparent cells: the divide-by-2 idiom `q <= ~q`.
    fn isToggle(w: *Walker, ci: usize) bool {
        const c = w.mod.cells[ci];
        const d = portBits(c, "D") orelse return false;
        const q = portBits(c, "Q") orelse return false;
        if (d.len != 1 or q.len != 1) return false;
        if (d[0] != .sig or q[0] != .sig) return false;
        return w.foldsBack(d[0].sig, ci, 0);
    }

    fn foldsBack(w: *Walker, bit: u32, ci: usize, depth: u8) bool {
        if (depth > 8) return false;
        const drv = w.mod.driver_of.get(bit) orelse return false;
        const dci = drv.cell orelse return false;
        if (dci == ci) return std.mem.eql(u8, drv.port, "Q");
        if (!cells.isTransparent(w.mod.cells[dci].type)) return false;
        var any = false;
        for (w.mod.cells[dci].ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b != .sig) continue;
                any = true;
                if (!w.foldsBack(b.sig, ci, depth + 1)) return false;
            }
        }
        return any;
    }

    // Only constants are statically known selects; anything else
    // needs value propagation we deliberately do not have (v1).
    fn constSel(s: []const ir.bits.Bit) ?bool {
        if (s.len == 0) return null;
        var val: ?bool = null;
        for (s) |b| switch (b) {
            .zero => {
                if (val != null and val.? != false) return null;
                val = false;
            },
            .one => {
                if (val != null and val.? != true) return null;
                val = true;
            },
            else => return null,
        };
        return val;
    }

    fn describeSelect(w: *Walker, s: []const ir.bits.Bit) error{OutOfMemory}![]u8 {
        if (s.len == 0) return w.alloc.dupe(u8, "missing");
        return w.describeBit(s[0]);
    }

    // One record per pin: muxes and gates recur through the memo,
    // so without this one select would repeat per downstream flop.
    fn recordControl(w: *Walker, ci: usize, pin: []const u8, dom: Domain) error{OutOfMemory}!void {
        for (w.controls.items) |cp| {
            if (cp.cell == ci and std.mem.eql(u8, cp.pin, pin)) return;
        }
        try w.controls.append(w.alloc, .{ .cell = ci, .pin = try w.alloc.dupe(u8, pin), .domain = dom });
    }

    // Flop-Q legs are enables even when their master matches the
    // clock: enables are almost always flopped, and the domain
    // alone cannot tell them from clock legs. Sees through the
    // buffer chains slang hangs on every net, lane-aware.
    fn drivenByFlop(w: *Walker, bit: u32) bool {
        return w.flopDriver(bit) != null;
    }

    // The sequential cell driving a leg, if any, through
    // buffers: enables report their master, so counting needs
    // the cell to tell dividers from enables.
    fn flopDriver(w: *Walker, bit: u32) ?usize {
        var cur = bit;
        for (0..8) |_| {
            const drv = w.mod.driver_of.get(cur) orelse return null;
            const dci = drv.cell orelse return null;
            const c = w.mod.cells[dci];
            if (!cells.isTransparent(c.type)) {
                if (cells.isSequential(c.type) and std.mem.eql(u8, drv.port, "Q")) return dci;
                return null;
            }
            cur = transparentLane(c, cur) orelse return null;
        }
        return null;
    }

    // Flop-driven legs count as clocks only when declared (the
    // SDC names the pin a clock) or toggling (a divider output):
    // data flops gate clocks, dividers drive them onward.
    fn countAsClock(w: *Walker, bit: u32) bool {
        if (w.roots.get(bit) != null) return true;
        const fci = w.flopDriver(bit) orelse return true;
        return w.isToggle(fci);
    }

    fn describeBit(w: *Walker, b: ir.bits.Bit) error{OutOfMemory}![]u8 {
        if (b != .sig) return w.alloc.dupe(u8, "constant");
        const drv = w.mod.driver_of.get(b.sig) orelse return w.alloc.dupe(u8, "undriven");
        if (drv.cell) |ci| return std.fmt.allocPrint(w.alloc, "cell {s}", .{w.mod.cells[ci].name});
        return std.fmt.allocPrint(w.alloc, "port {s}", .{drv.port});
    }

    fn make(w: *Walker, name: []const u8, root: []const u8, notes: []const []const u8) error{OutOfMemory}!Domain {
        const owned = try w.alloc.dupe(u8, name);
        const legs = try w.alloc.alloc([]const u8, 1);
        legs[0] = owned;
        return .{
            .name = owned,
            .root = try w.alloc.dupe(u8, root),
            .notes = try w.dupeNotes(notes),
            .legs = legs,
            .sels = &.{},
            .muxes = &.{},
        };
    }

    // Muxed clocks keep every leg: the joined name is display,
    // legs are what rules reason over. Sorted, so output diffs.
    fn makeUnion(w: *Walker, legs: []const []const u8, sels: []const LegSel, muxes: []const usize, root: []const u8, note: []const u8) error{OutOfMemory}!Domain {
        std.debug.assert(legs.len > 1);
        // Select-less OR unions carry no selects; every
        // consumer len-guards before zipping legs to sels.
        std.debug.assert(legs.len == sels.len or sels.len == 0);
        var total: usize = legs.len - 1;
        for (legs) |l| total += l.len;
        const name = try w.alloc.alloc(u8, total);
        var off: usize = 0;
        for (legs, 0..) |l, i| {
            if (i > 0) {
                name[off] = '+';
                off += 1;
            }
            @memcpy(name[off..][0..l.len], l);
            off += l.len;
        }
        const owned = try w.alloc.alloc([]const u8, legs.len);
        for (legs, 0..) |l, i| owned[i] = try w.alloc.dupe(u8, l);
        return .{
            .name = name,
            .root = try w.alloc.dupe(u8, root),
            .notes = try w.dupeNotes(&.{note}),
            .legs = owned,
            .sels = try w.alloc.dupe(LegSel, sels),
            .muxes = try w.alloc.dupe(usize, muxes),
        };
    }

    // Every string owned: the assignment outlives nothing it borrows.
    fn dupeNotes(w: *Walker, in: []const []const u8) error{OutOfMemory}![][]const u8 {
        const out = try w.alloc.alloc([]const u8, in.len);
        for (in, 0..) |n, i| out[i] = try w.alloc.dupe(u8, n);
        return out;
    }

    fn withNote(w: *Walker, dom: Domain, text: []const u8) error{OutOfMemory}!Domain {
        const out = try w.alloc.alloc([]const u8, dom.notes.len + 1);
        @memcpy(out[0..dom.notes.len], dom.notes);
        out[dom.notes.len] = try w.alloc.dupe(u8, text);
        return .{ .name = dom.name, .root = dom.root, .notes = out, .legs = dom.legs, .sels = dom.sels, .muxes = dom.muxes };
    }
};
