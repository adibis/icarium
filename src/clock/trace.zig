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
};

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
pub fn assign(parent: std.mem.Allocator, mod: *const ir.types.Module, model: *const sdc.model.Model) error{OutOfMemory}!Assignment {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();

    var memo = std.AutoHashMapUnmanaged(u32, Domain){};
    var active = std.AutoHashMapUnmanaged(u32, void){};
    var flops: std.ArrayListUnmanaged(FlopDomain) = .empty;
    var controls: std.ArrayListUnmanaged(ControlPin) = .empty;
    var combine_sets = std.AutoHashMapUnmanaged(u32, std.StringHashMapUnmanaged(void)){};
    var w = Walker{ .mod = mod, .model = model, .alloc = alloc, .memo = &memo, .active = &active, .controls = &controls, .combines = &combine_sets };
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
        const a = portBits(c, "A") orelse return null;
        if (a.len != 1 or a[0] != .sig) return null;
        cur = a[0].sig;
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

// Single declared clocks only: synthetic, unknown, and union
// names never identify a gate's clock leg.
fn isClockDomain(name: []const u8) bool {
    if (std.mem.eql(u8, name, "unknown")) return false;
    if (std.mem.startsWith(u8, name, "port:")) return false;
    return std.mem.indexOfScalar(u8, name, '+') == null;
}

const Walker = struct {
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    alloc: std.mem.Allocator,
    memo: *std.AutoHashMapUnmanaged(u32, Domain),
    active: *std.AutoHashMapUnmanaged(u32, void),
    controls: *std.ArrayListUnmanaged(ControlPin),
    combines: *std.AutoHashMapUnmanaged(u32, std.StringHashMapUnmanaged(void)),

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
        if (sdc.model.rootClock(w.model, port)) |c| return w.make(c, port, &.{});
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
        };
    }

    fn throughCell(w: *Walker, bit: u32, ci: usize) error{OutOfMemory}!Domain {
        const c = w.mod.cells[ci];
        if (cells.isTransparent(c.type)) return w.throughTransparent(c);
        if (cells.isClockMux(c.type)) return w.throughMux(ci);
        if (cells.isClockGate(c.type)) return w.throughGate(bit, ci);
        if (std.mem.eql(u8, c.type, "$or")) return w.throughOrMux(bit, ci);
        if (cells.isSequential(c.type)) return w.throughSequential(ci);
        if (c.blackbox) return w.make("unknown", "", &.{"blackbox-driven clock"});
        return w.unhandled(c);
    }

    // Transparent cells pass the domain through; only inverters
    // earn the note, so buffers stay silent on clock paths.
    fn throughTransparent(w: *Walker, c: ir.types.Cell) error{OutOfMemory}!Domain {
        var inputs: std.ArrayListUnmanaged(ir.bits.Bit) = .empty;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| try inputs.append(w.alloc, b);
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
        try w.recordControl(ci, "S", try w.resolveBits(s));
        const da = try w.resolveBits(a);
        const db = try w.resolveBits(b);
        if (std.mem.eql(u8, da.name, "unknown") or std.mem.eql(u8, db.name, "unknown"))
            return w.make("unknown", "", &.{"clock mux unresolved leg"});
        var all: std.ArrayListUnmanaged([]const u8) = .empty;
        for (da.legs) |l| try all.append(w.alloc, l);
        for (db.legs) |l| try all.append(w.alloc, l);
        std.mem.sort([]const u8, all.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        var n: usize = 0;
        for (all.items) |l| {
            if (n == 0 or !std.mem.eql(u8, all.items[n - 1], l)) {
                all.items[n] = l;
                n += 1;
            }
        }
        const sel_desc = try w.describeSelect(s);
        defer w.alloc.free(sel_desc);
        const note = try std.fmt.allocPrint(w.alloc, "clock mux select: {s}", .{sel_desc});
        defer w.alloc.free(note);
        if (n == 1) return w.withNote(da, note);
        const root = try std.fmt.allocPrint(w.alloc, "mux:{s}", .{c.name});
        defer w.alloc.free(root);
        return w.makeUnion(all.items[0..n], root, note);
    }

    // Gate-built clock muxes (a glitch-free mux's output stage
    // is an OR of clock-and-enable ANDs): every leg feeding the
    // resolved bit must be an $and with exactly one clock leg,
    // and the union of those legs is the domain. Anything else
    // ORed onto a clock path keeps today's unhandled verdict.
    fn throughOrMux(w: *Walker, bit: u32, ci: usize) error{OutOfMemory}!Domain {
        const c = w.mod.cells[ci];
        const idx = outBitIndex(c, bit) orelse return w.unhandled(c);
        var first: ?Domain = null;
        var all: std.ArrayListUnmanaged([]const u8) = .empty;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            if (idx >= p.bits.len) return w.unhandled(c);
            const b = p.bits[idx];
            if (b != .sig) return w.unhandled(c);
            const and_ci = gateLeg(w.mod, b.sig) orelse return w.unhandled(c);
            if (try w.clockLegs(and_ci) != 1) return w.unhandled(c);
            const d = try w.resolveBit(b.sig);
            if (!isClockDomain(d.name)) return w.unhandled(c);
            if (first == null) first = d;
            for (d.legs) |l| try all.append(w.alloc, l);
        }
        if (first == null) return w.unhandled(c);
        std.mem.sort([]const u8, all.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        var n: usize = 0;
        for (all.items) |l| {
            if (n == 0 or !std.mem.eql(u8, all.items[n - 1], l)) {
                all.items[n] = l;
                n += 1;
            }
        }
        if (n == 1) return w.withNote(first.?, "or-built clock mux");
        const root = try std.fmt.allocPrint(w.alloc, "ormux:{s}", .{c.name});
        defer w.alloc.free(root);
        return w.makeUnion(all.items[0..n], root, "or-built clock mux");
    }

    fn unhandled(w: *Walker, c: ir.types.Cell) error{OutOfMemory}!Domain {
        const why = try std.fmt.allocPrint(w.alloc, "unhandled {s} on clock path", .{c.type});
        defer w.alloc.free(why);
        return w.make("unknown", "", &.{why});
    }

    // Clock-domain inputs on a gate's legs. Unknown legs read as
    // enables, mirroring the gate doctrine: only the count of
    // proven clock legs constrains the caller.
    fn clockLegs(w: *Walker, ci: usize) error{OutOfMemory}!usize {
        const c = w.mod.cells[ci];
        var n: usize = 0;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b != .sig) continue;
                const d = try w.resolveBit(b.sig);
                if (isClockDomain(d.name)) n += 1;
            }
        }
        return n;
    }

    // A clock gate passes its clock leg and notes the rest as
    // enables; ambiguous legs stay unknown rather than guessed.
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
                if (isClockDomain(d.name)) {
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
    // alone cannot tell them from clock legs.
    fn drivenByFlop(w: *Walker, bit: u32) bool {
        const drv = w.mod.driver_of.get(bit) orelse return false;
        const dci = drv.cell orelse return false;
        return cells.isSequential(w.mod.cells[dci].type) and std.mem.eql(u8, drv.port, "Q");
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
        };
    }

    // Muxed clocks keep every leg: the joined name is display,
    // legs are what rules reason over. Sorted, so output diffs.
    fn makeUnion(w: *Walker, legs: []const []const u8, root: []const u8, note: []const u8) error{OutOfMemory}!Domain {
        std.debug.assert(legs.len > 1);
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
        return .{ .name = dom.name, .root = dom.root, .notes = out, .legs = dom.legs };
    }
};
