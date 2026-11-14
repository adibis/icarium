// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const ir = @import("../ir.zig");

// One synchronizer verdict per flop: chain depth plus the ordered
// stages behind it. Depth is memoized, so a long shift chain costs
// one walk total instead of one walk per head.
pub const Entry = struct {
    depth: u32,
    stages: []usize,
};

pub const Table = struct {
    // The module arrives per call, never stored: tables outlive
    // the frame that built them, so a stored pointer would dangle.
    alloc: std.mem.Allocator,
    backing: *std.heap.ArenaAllocator,
    domains: std.AutoHashMapUnmanaged(usize, clock.trace.Domain),
    // Dense per-cell domain index: rules ask per crossing, and a
    // hash per crossing costs more than the rule itself. Entries
    // point at the map's values, which never move after build.
    by_cell: []?*const clock.trace.Domain,
    d_bit_to_flop: std.AutoHashMapUnmanaged(u32, usize),
    srst_data_bit_to_flop: std.AutoHashMapUnmanaged(u32, usize),
    // Dense chain memo for the same reason: one indexed load.
    memo: []?Entry,
    combines: []clock.trace.Combine,
    // Dense gray-encode memo: one verdict per source cell, so
    // the fanin walk runs once per cell, never per crossing.
    gray_memo: []?bool,
    // Gating verdicts per (destination, clock): the enable/mux
    // fanin walk runs once per pair, never per crossing.
    gating_memo: std.AutoHashMapUnmanaged(usize, std.StringHashMapUnmanaged(bool)),

    pub fn deinit(self: *Table) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }

    pub fn domainOf(self: *const Table, cell: usize) ?clock.trace.Domain {
        if (cell >= self.by_cell.len) return null;
        return if (self.by_cell[cell]) |d| d.* else null;
    }

    pub fn grayVerdict(t: *const Table, sc: usize) ?bool {
        if (sc >= t.gray_memo.len) return null;
        return t.gray_memo[sc];
    }

    pub fn storeGray(t: *Table, sc: usize, v: bool) void {
        if (sc >= t.gray_memo.len) return;
        t.gray_memo[sc] = v;
    }

    pub fn gatingVerdict(t: *const Table, dst: usize, clk: []const u8) ?bool {
        const inner = t.gating_memo.get(dst) orelse return null;
        return inner.get(clk);
    }

    pub fn storeGating(t: *Table, dst: usize, clk: []const u8, v: bool) error{OutOfMemory}!void {
        const slot = try t.gating_memo.getOrPut(t.alloc, dst);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        const inner = try slot.value_ptr.getOrPut(t.alloc, clk);
        // Clock names copy out: probes borrow batch crossings.
        if (!inner.found_existing) inner.key_ptr.* = try t.alloc.dupe(u8, clk);
        inner.value_ptr.* = v;
    }

    // Work scratch rooted at the real allocator: walk garbage
    // frees with the arena instead of piling into a batch arena
    // whose free is a no-op.
    pub fn workArena(t: *const Table) std.heap.ArenaAllocator {
        return std.heap.ArenaAllocator.init(t.backing.child_allocator);
    }

    fn readers(_: *const Table, mod: *const ir.types.Module, bit: u32) usize {
        const loads = mod.loads_of.get(bit) orelse return 0;
        return loads.items.len;
    }

    // Length of the chain starting at head, head included. A stage
    // extends the chain only through a single-reader Q into a
    // same-clock D, directly, over a reset mux, or through
    // transparent buffers: slang buffers every net, so direct-Q
    // rigidity reads clean chains short. Inversions ride along:
    // data chains need timing, not value agreement (reset chains
    // keep the stricter value contract). Packed shift registers
    // read their effective intra-cell depth instead.
    // Cost: O(chain) once per head, memoized; revisits are O(1).
    pub fn chainDepth(t: *Table, mod: *const ir.types.Module, head: usize, head_clock: []const u8) error{OutOfMemory}!Entry {
        if (t.memo[head]) |e| return e;
        const c = mod.cells[head];
        const d = c.portBits("D");
        const q = c.portBits("Q");
        if (d == null or q == null or d.?.len != 1 or q.?.len != 1) {
            if (try t.packedDepth(mod, head)) |e| {
                t.memo[head] = e;
                return e;
            }
            const one = Entry{ .depth = 1, .stages = try oneStage(t.alloc, head) };
            t.memo[head] = one;
            return one;
        }
        var stages = std.ArrayListUnmanaged(usize).empty;
        try stages.append(t.alloc, head);
        var visited = std.AutoHashMapUnmanaged(usize, void).empty;
        try visited.put(t.alloc, head, {});
        var cur = head;
        while (true) {
            const cq = mod.cells[cur].portBits("Q").?[0];
            if (cq != .sig) break;
            if (t.readers(mod, cq.sig) != 1) break;
            const db = stepThroughTransparent(mod, cq.sig) orelse break;
            const nxt = t.d_bit_to_flop.get(db) orelse
                t.srst_data_bit_to_flop.get(db) orelse break;
            if (visited.contains(nxt)) break;
            const dom = t.domains.get(nxt) orelse break;
            if (!std.mem.eql(u8, dom.name, head_clock)) break;
            try stages.append(t.alloc, nxt);
            try visited.put(t.alloc, nxt, {});
            cur = nxt;
        }
        const e = Entry{ .depth = @intCast(stages.items.len), .stages = try stages.toOwnedSlice(t.alloc) };
        t.memo[head] = e;
        return e;
    }

    // A gate between the stages: head Q feeds comb whose Y lands on a
    // same-clock D. Single hop only; deeper shapes belong to other
    // rules. A reset mux on the far D is part of that flop, not a gate.
    // Transparent cells never count (a buffer is wire, an inverter
    // preserves the full-cycle resolution), and the link must be
    // dedicated at both ends: a tapped head or a shared gate output
    // feeds logic, not a second stage.
    pub fn hasInterStageComb(t: *const Table, mod: *const ir.types.Module, head: usize) ?usize {
        const c = mod.cells[head];
        const q = c.portBits("Q") orelse return null;
        if (q.len != 1 or q[0] != .sig) return null;
        const head_clock = (t.domains.get(head) orelse return null).name;
        const ci = singleConsumer(mod, q[0].sig) orelse return null;
        const m = mod.cells[ci];
        if (clock.cells.isSequential(m.type)) return null;
        if (clock.cells.isTransparent(m.type)) return null;
        const y = m.portBits("Y") orelse return null;
        for (y) |yb| {
            if (yb != .sig) continue;
            if (singleConsumer(mod, yb.sig) == null) continue;
            const nxt = t.d_bit_to_flop.get(yb.sig) orelse continue;
            if (nxt == head) continue;
            const dom = t.domains.get(nxt) orelse continue;
            if (!std.mem.eql(u8, dom.name, head_clock)) continue;
            if (t.srst_data_bit_to_flop.get(q[0].sig)) |behind| {
                if (behind == nxt) continue;
            }
            return nxt;
        }
        return null;
    }

    // True when dst D is a reset mux whose data leg carries
    // src_bit: the crossing enters through the flop's own reset.
    pub fn resetMuxEntry(t: *const Table, mod: *const ir.types.Module, dst: usize, src_bit: u32) bool {
        const leg = t.resetMuxDataLeg(mod, dst) orelse return false;
        for (leg) |b| {
            if (b == .sig and b.sig == src_bit) return true;
        }
        return false;
    }

    // Data leg of a sync-reset $mux on D, or null when D is not that
    // shape: Y must equal D lane for lane, exactly one leg all
    // constant, every Y bit single-reader. Enable muxes, live legs,
    // and $pmux nests never qualify, so chains stop in front of them.
    fn resetMuxDataLeg(t: *const Table, mod: *const ir.types.Module, head: usize) ?[]ir.bits.Bit {
        const c = mod.cells[head];
        const d = c.portBits("D") orelse return null;
        if (d.len == 0 or d[0] != .sig) return null;
        const drv = mod.driver_of.get(d[0].sig) orelse return null;
        const mci = drv.cell orelse return null;
        if (!std.mem.eql(u8, drv.port, "Y")) return null;
        const m = mod.cells[mci];
        if (!std.mem.eql(u8, m.type, "$mux")) return null;
        const y = m.portBits("Y") orelse return null;
        const a = m.portBits("A") orelse return null;
        const b = m.portBits("B") orelse return null;
        if (y.len != d.len or a.len != d.len or b.len != d.len) return null;
        for (y, d) |yb, db| {
            if (yb != .sig or db != .sig or yb.sig != db.sig) return null;
        }
        for (y) |yb| {
            if (t.readers(mod, yb.sig) != 1) return null;
        }
        const a_const = ir.bits.allConst(a);
        const b_const = ir.bits.allConst(b);
        if (a_const == b_const) return null;
        return if (b_const) a else b;
    }

    // Effective depth of a packed shift register: D lanes are the
    // flop's own Q bits except exactly one external lane, followed
    // lane to lane while each tap stays single-reader. Anything else
    // (buses, gray counters, enables) is not this shape.
    fn packedDepth(t: *Table, mod: *const ir.types.Module, head: usize) error{OutOfMemory}!?Entry {
        const c = mod.cells[head];
        const q = c.portBits("Q") orelse return null;
        const d = c.portBits("D") orelse return null;
        if (q.len < 2 or d.len != q.len) return null;
        for (q) |qb| if (qb != .sig) return null;
        var d_bits: []ir.bits.Bit = d;
        if (t.resetMuxDataLeg(mod, head)) |leg| d_bits = leg;
        for (d_bits) |db| if (db != .sig) return null;
        var q_index = std.AutoHashMapUnmanaged(u32, usize).empty;
        for (q, 0..) |qb, i| {
            if (q_index.contains(qb.sig)) return null;
            try q_index.put(t.alloc, qb.sig, i);
        }
        var succ = std.AutoHashMapUnmanaged(usize, usize).empty;
        var external: ?usize = null;
        for (d_bits, 0..) |db, i| {
            const j = q_index.get(db.sig) orelse {
                if (external != null) return null;
                external = i;
                continue;
            };
            if (succ.contains(j)) return null;
            try succ.put(t.alloc, j, i);
        }
        var cur = external orelse return null;
        var visited = std.AutoHashMapUnmanaged(usize, void).empty;
        try visited.put(t.alloc, cur, {});
        var depth: u32 = 1;
        while (true) {
            if (t.readers(mod, q[cur].sig) != 1) break;
            const nxt = succ.get(cur) orelse break;
            if (visited.contains(nxt)) break;
            try visited.put(t.alloc, nxt, {});
            depth += 1;
            cur = nxt;
        }
        if (depth < 2) return null;
        // One cell holds every stage: depth counts, stages names it once.
        return Entry{ .depth = depth, .stages = try oneStage(t.alloc, head) };
    }
};

pub fn build(
    parent: std.mem.Allocator,
    mod: *const ir.types.Module,
    asg: *const clock.trace.Assignment,
) error{OutOfMemory}!Table {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();

    var domains = std.AutoHashMapUnmanaged(usize, clock.trace.Domain).empty;
    for (asg.flops) |f| try domains.put(alloc, f.cell, f.domain);

    var d_bit_to_flop = std.AutoHashMapUnmanaged(u32, usize).empty;
    for (mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type)) continue;
        if (clock.cells.isLatch(c.type)) continue;
        const d = c.portBits("D") orelse continue;
        const q = c.portBits("Q") orelse continue;
        if (d.len != 1 or q.len != 1) continue;
        if (d[0] != .sig) continue;
        try d_bit_to_flop.put(alloc, d[0].sig, ci);
    }

    // Combines copy over, strings included: the assignment that
    // owns them may die before the table does.
    var combines = std.ArrayListUnmanaged(clock.trace.Combine).empty;
    for (asg.combines) |cb| {
        var names = std.ArrayListUnmanaged([]const u8).empty;
        for (cb.clocks) |n| try names.append(alloc, try alloc.dupe(u8, n));
        try combines.append(alloc, .{ .cell = cb.cell, .bit = cb.bit, .clocks = try names.toOwnedSlice(alloc) });
    }
    const by_cell = try alloc.alloc(?*const clock.trace.Domain, mod.cells.len);
    @memset(by_cell, null);
    var dit = domains.iterator();
    while (dit.next()) |e| by_cell[e.key_ptr.*] = e.value_ptr;
    const memo = try alloc.alloc(?Entry, mod.cells.len);
    @memset(memo, null);
    const gray_memo = try alloc.alloc(?bool, mod.cells.len);
    @memset(gray_memo, null);
    var t = Table{
        .alloc = alloc,
        .backing = backing,
        .domains = domains,
        .by_cell = by_cell,
        .d_bit_to_flop = d_bit_to_flop,
        .srst_data_bit_to_flop = .{},
        .memo = memo,
        .combines = try combines.toOwnedSlice(alloc),
        .gray_memo = gray_memo,
        .gating_memo = .{},
    };
    // First flop wins a shared data bit, in cell order: a shared
    // bit has two readers anyway, so walkers reject it first.
    for (mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type)) continue;
        if (clock.cells.isLatch(c.type)) continue;
        const d = c.portBits("D") orelse continue;
        const q = c.portBits("Q") orelse continue;
        if (d.len != 1 or q.len != 1) continue;
        const leg = t.resetMuxDataLeg(mod, ci) orelse continue;
        if (leg.len == 0 or leg[0] != .sig) continue;
        const slot = try t.srst_data_bit_to_flop.getOrPut(alloc, leg[0].sig);
        if (!slot.found_existing) slot.value_ptr.* = ci;
    }
    return t;
}

fn oneStage(alloc: std.mem.Allocator, head: usize) error{OutOfMemory}![]usize {
    const out = try alloc.alloc(usize, 1);
    out[0] = head;
    return out;
}

// The bit's sole consuming cell, or null when the value
// escapes: tied legs on one gate still count as one consumer,
// but a second cell or a port tap voids dedication.
fn singleConsumer(mod: *const ir.types.Module, bit: u32) ?usize {
    const loads = mod.loads_of.get(bit) orelse return null;
    var seen: ?usize = null;
    for (loads.items) |loc| {
        const ci = loc.cell orelse return null;
        if (seen) |s| {
            if (s != ci) return null;
        } else seen = ci;
    }
    return seen;
}

// Forward through single-consumer transparent cells to the
// driven bit. A tap after a buffer breaks the step exactly
// as a Q tap breaks the chain: the value escapes either way.
fn stepThroughTransparent(mod: *const ir.types.Module, bit: u32) ?u32 {
    var cur = bit;
    for (0..8) |_| {
        const loads = mod.loads_of.get(cur) orelse return cur;
        if (loads.items.len == 0) return cur;
        const only = singleConsumer(mod, cur) orelse return null;
        const c = mod.cells[only];
        if (!clock.cells.isTransparent(c.type)) return cur;
        cur = transparentOut(c, loads.items[0].port, cur) orelse return null;
    }
    return null;
}

// Output bit at the input's index: transparent cells pass
// lane-to-lane, so the load position picks the driven bit.
fn transparentOut(c: ir.types.Cell, port: []const u8, bit: u32) ?u32 {
    const a = c.portBits(port) orelse return null;
    const y = c.portBits("Y") orelse return null;
    for (a, 0..) |b, i| {
        if (b == .sig and b.sig == bit) {
            if (i < y.len and y[i] == .sig) return y[i].sig;
            return null;
        }
    }
    return null;
}
