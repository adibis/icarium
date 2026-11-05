const std = @import("std");
const cells = @import("cells.zig");
const clock = @import("../clock.zig");
const ir = @import("../ir.zig");
const trace = @import("trace.zig");

// Recognised reset-synchroniser chains: the async-assert /
// sync-deassert idiom, same-clock flops sharing one async
// reset, chained Q→D behind a constant-fed head. Structural
// matches only; user marks join the member set, never chains.
// Single-flop syncs count with proof of service: a lone flop
// is a synchroniser only when its Q reaches an async pin.
pub const Chain = struct {
    // Tail first, head last: flops[0] faces downstream.
    flops: []usize,
    head_d: ir.bits.Bit,
    polarity: trace.Polarity,
};

pub const Load = struct { cell: usize, via_comb: bool, comb: usize };

// Async-pin arrivals reachable from a Q through combinational
// loads: sequential cells end the walk unexpanded, so a flop in
// the middle starts a new release event this walk must not cross.
pub fn asyncLoads(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    start: usize,
) error{OutOfMemory}![]Load {
    var found = std.ArrayListUnmanaged(Load).empty;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(FrontBit).empty;
    const q = portBits(mod.cells[start], "Q") orelse return &.{};
    for (q) |b| {
        if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = 0, .via_comb = false, .comb = 0 });
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const fb = frontier.items[head];
        if (seen.contains(fb.bit)) continue;
        try seen.put(alloc, fb.bit, {});
        const loads = mod.loads_of.get(fb.bit) orelse continue;
        for (loads.items) |loc| {
            const ci = loc.cell orelse continue;
            const c = mod.cells[ci];
            if (clock.cells.isSequential(c.type)) {
                const ap = cells.canonicalAsyncPin(c) orelse continue;
                if (!std.mem.eql(u8, loc.port, ap.pin)) continue;
                try found.append(alloc, .{ .cell = ci, .via_comb = fb.via_comb, .comb = fb.comb });
                continue;
            }
            if (c.blackbox or fb.depth >= 12) continue;
            // Plain buffers pass silent: slang buffers every net,
            // so only value-changing gates mark the path edited.
            var via = fb.via_comb;
            var first = fb.comb;
            if (!std.mem.eql(u8, c.type, "$buf") and !via) {
                via = true;
                first = ci;
            }
            for (c.ports) |p| {
                if (p.direction != .output) continue;
                if (!std.mem.eql(u8, p.name, "Y") and !std.mem.eql(u8, p.name, "Q")) continue;
                for (p.bits) |ob| {
                    if (ob == .sig) try frontier.append(alloc, .{ .bit = ob.sig, .depth = fb.depth + 1, .via_comb = via, .comb = first });
                }
            }
        }
    }
    return found.toOwnedSlice(alloc);
}

const FrontBit = struct { bit: u32, depth: u8, via_comb: bool, comb: usize };

pub const Syncs = struct {
    backing: *std.heap.ArenaAllocator,
    chains: []Chain,
    members: std.StringHashMapUnmanaged(void),

    pub fn deinit(self: *Syncs) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }

    pub fn isMember(self: *const Syncs, cell_name: []const u8) bool {
        return self.members.contains(cell_name);
    }
};

pub const DomainsMap = std.AutoHashMapUnmanaged(usize, clock.trace.Domain);
pub const MarksSet = std.StringHashMapUnmanaged(void);

pub fn find(
    parent: std.mem.Allocator,
    mod: *const ir.types.Module,
    view: *const trace.View,
    domains: *const DomainsMap,
    extra: *const MarksSet,
) error{OutOfMemory}!Syncs {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();

    var by_cell = std.AutoHashMapUnmanaged(usize, *const trace.FlopReset).empty;
    for (view.flops) |*fr| try by_cell.put(alloc, fr.cell, fr);

    var members = std.StringHashMapUnmanaged(void).empty;
    var eit = extra.iterator();
    while (eit.next()) |e| try members.put(alloc, e.key_ptr.*, {});

    var best = std.AutoHashMapUnmanaged(usize, Chain).empty;
    for (mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        const fr = by_cell.get(ci) orelse continue;
        const ar = canonicalAsync(c, fr) orelse continue;
        const tail_clk = domains.get(ci) orelse continue;
        if (std.mem.eql(u8, tail_clk.name, "unknown")) continue;
        const found = try traceChain(alloc, mod, &by_cell, domains, ci, ar);
        const ch = found orelse continue;
        if (ch.flops.len < 2) {
            // A lone constant-fed flop proves synchroniser duty by
            // serving an async pin; anything else is plain logic.
            const loads = try asyncLoads(alloc, mod, ci);
            if (loads.len == 0) continue;
        }
        const head = ch.flops[ch.flops.len - 1];
        const slot = try best.getOrPut(alloc, head);
        if (!slot.found_existing or ch.flops.len > slot.value_ptr.flops.len) {
            slot.value_ptr.* = ch;
        }
    }
    var chains = std.ArrayListUnmanaged(Chain).empty;
    var bit = best.iterator();
    while (bit.next()) |e| {
        try chains.append(alloc, e.value_ptr.*);
        for (e.value_ptr.flops) |f| try members.put(alloc, mod.cells[f].name, {});
    }
    std.mem.sort(Chain, chains.items, mod, struct {
        fn less(m: *const ir.types.Module, a: Chain, b: Chain) bool {
            return std.mem.order(u8, m.cells[a.flops[0]].name, m.cells[b.flops[0]].name) == .lt;
        }
    }.less);
    return .{
        .backing = backing,
        .chains = try chains.toOwnedSlice(alloc),
        .members = members,
    };
}

// One canonical async pin per flop, ARST first: SET pins never
// seed recognition, matching the reference pin order.
fn canonicalAsync(c: ir.types.Cell, fr: *const trace.FlopReset) ?trace.AsyncReset {
    const want = cells.canonicalAsyncPin(c) orelse return null;
    for (fr.async) |ar| {
        if (std.mem.eql(u8, ar.pin, want.pin)) return ar;
    }
    return null;
}

const Sig = struct { origin: trace.Origin, ref: []const u8, flips: u32 };

// Walk Q→D back from the tail; the chain counts only when its
// head is constant-fed. Anything else (ports, comb, foreign
// clocks, split resets, multi-bit D) fails the shape. Buffers
// pass through: slang buffers every net, so direct-Q rigidity
// would blind the finder on real netlists. Inverters fail it:
// a flipped inter-stage value voids the head-D contract.
fn traceChain(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    by_cell: *const std.AutoHashMapUnmanaged(usize, *const trace.FlopReset),
    domains: *const DomainsMap,
    tail: usize,
    tail_ar: trace.AsyncReset,
) error{OutOfMemory}!?Chain {
    const tail_clk = (domains.get(tail) orelse return null).name;
    const sig = Sig{ .origin = tail_ar.origin, .ref = tail_ar.ref, .flips = tail_ar.flips };
    var chain = std.ArrayListUnmanaged(usize).empty;
    try chain.append(alloc, tail);
    var cur = tail;
    for (0..6) |_| {
        const c = mod.cells[cur];
        const d = portBits(c, "D") orelse return null;
        if (d.len != 1) return null;
        if (d[0] != .sig) {
            return .{
                .flops = try chain.toOwnedSlice(alloc),
                .head_d = d[0],
                .polarity = paramPolarity(mod.cells[tail], tail_ar.pin),
            };
        }
        const src = stepThroughBufs(mod, d[0].sig) orelse return null;
        if (src.bit) |hb| {
            return .{
                .flops = try chain.toOwnedSlice(alloc),
                .head_d = hb,
                .polarity = paramPolarity(mod.cells[tail], tail_ar.pin),
            };
        }
        const di = src.cell.?;
        const dc = mod.cells[di];
        if (!clock.cells.isSequential(dc.type) or clock.cells.isLatch(dc.type)) return null;
        const dfr = by_cell.get(di) orelse return null;
        const dar = canonicalAsync(dc, dfr) orelse return null;
        const dclk = domains.get(di) orelse return null;
        if (std.mem.eql(u8, dclk.name, "unknown")) return null;
        if (!std.mem.eql(u8, dclk.name, tail_clk)) return null;
        const dsig = Sig{ .origin = dar.origin, .ref = dar.ref, .flips = dar.flips };
        if (dsig.origin != sig.origin or !std.mem.eql(u8, dsig.ref, sig.ref) or dsig.flips != sig.flips) return null;
        try chain.append(alloc, di);
        cur = di;
    }
    return null;
}

// One step carries either a flop Q driver or a constant, never
// both: exactly one field reads non-null on every return.
const BufStep = struct { cell: ?usize, bit: ?ir.bits.Bit };

// Back through single-bit buffers to the driving flop Q or the
// feeding constant. Anything else (ports, gates, inverters, deep
// buffer runs) fails the step and with it the chain.
fn stepThroughBufs(mod: *const ir.types.Module, bit: u32) ?BufStep {
    var cur = bit;
    for (0..8) |_| {
        const drv = mod.driver_of.get(cur) orelse return null;
        const ci = drv.cell orelse return null;
        const c = mod.cells[ci];
        if (std.mem.eql(u8, c.type, "$buf")) {
            const a = portBits(c, "A") orelse return null;
            if (a.len != 1) return null;
            if (a[0] != .sig) return .{ .cell = null, .bit = a[0] };
            cur = a[0].sig;
            continue;
        }
        if (!std.mem.eql(u8, drv.port, "Q")) return null;
        return .{ .cell = ci, .bit = null };
    }
    return null;
}

// The pin's own parameter, trailing bit wins; absent reads
// high, the reference default Yosys never exercises.
pub fn paramPolarity(c: ir.types.Cell, pin: []const u8) trace.Polarity {
    const rp = cells.resetPins(c.type) orelse return .high;
    for (rp.async) |ap| {
        if (!std.mem.eql(u8, ap.pin, pin)) continue;
        for (c.params) |p| {
            if (!std.mem.eql(u8, p.name, ap.polarity_param)) continue;
            if (p.value != .str or p.value.str.len == 0) return .low;
            return if (p.value.str[p.value.str.len - 1] == '1') .high else .low;
        }
        return .high;
    }
    return .high;
}

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
    }
    return null;
}
