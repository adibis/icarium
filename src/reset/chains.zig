const std = @import("std");
const cells = @import("cells.zig");
const clock = @import("../clock.zig");
const ir = @import("../ir.zig");
const trace = @import("trace.zig");

// Recognised reset-synchroniser chains: the async-assert /
// sync-deassert idiom, N≥2 same-clock flops sharing one async
// reset, chained Q→D behind a constant-fed head. Structural
// matches only; user marks join the member set, never chains.
pub const Chain = struct {
    // Tail first, head last: flops[0] faces downstream.
    flops: []usize,
    head_d: ir.bits.Bit,
    polarity: trace.Polarity,
};

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
        if (ch.flops.len < 2) continue;
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
// clocks, split resets, multi-bit D) fails the shape.
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
        const drv = mod.driver_of.get(d[0].sig) orelse return null;
        const di = drv.cell orelse return null;
        if (!std.mem.eql(u8, drv.port, "Q")) return null;
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
