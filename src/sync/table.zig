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
    d_bit_to_flop: std.AutoHashMapUnmanaged(u32, usize),
    srst_data_bit_to_flop: std.AutoHashMapUnmanaged(u32, usize),
    memo: std.AutoHashMapUnmanaged(usize, Entry),

    pub fn deinit(self: *Table) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }

    pub fn domainOf(self: *const Table, cell: usize) ?clock.trace.Domain {
        return self.domains.get(cell);
    }

    fn readers(_: *const Table, mod: *const ir.types.Module, bit: u32) usize {
        const loads = mod.loads_of.get(bit) orelse return 0;
        return loads.items.len;
    }

    // Length of the chain starting at head, head included. A stage
    // extends the chain only through a single-reader Q into a
    // same-clock D, directly or over a reset mux. Packed shift
    // registers read their effective intra-cell depth instead.
    pub fn chainDepth(t: *Table, mod: *const ir.types.Module, head: usize, head_clock: []const u8) error{OutOfMemory}!Entry {
        if (t.memo.get(head)) |e| return e;
        const c = mod.cells[head];
        const d = portBits(c, "D");
        const q = portBits(c, "Q");
        if (d == null or q == null or d.?.len != 1 or q.?.len != 1) {
            if (try t.packedDepth(mod, head)) |e| {
                try t.memo.put(t.alloc, head, e);
                return e;
            }
            const one = Entry{ .depth = 1, .stages = try oneStage(t.alloc, head) };
            try t.memo.put(t.alloc, head, one);
            return one;
        }
        var stages = std.ArrayListUnmanaged(usize).empty;
        try stages.append(t.alloc, head);
        var visited = std.AutoHashMapUnmanaged(usize, void).empty;
        try visited.put(t.alloc, head, {});
        var cur = head;
        while (true) {
            const cq = portBits(mod.cells[cur], "Q").?[0];
            if (cq != .sig) break;
            if (t.readers(mod, cq.sig) != 1) break;
            const nxt = t.d_bit_to_flop.get(cq.sig) orelse
                t.srst_data_bit_to_flop.get(cq.sig) orelse break;
            if (visited.contains(nxt)) break;
            const dom = t.domains.get(nxt) orelse break;
            if (!std.mem.eql(u8, dom.name, head_clock)) break;
            try stages.append(t.alloc, nxt);
            try visited.put(t.alloc, nxt, {});
            cur = nxt;
        }
        const e = Entry{ .depth = @intCast(stages.items.len), .stages = try stages.toOwnedSlice(t.alloc) };
        try t.memo.put(t.alloc, head, e);
        return e;
    }

    // A gate between the stages: head Q feeds comb whose Y lands on a
    // same-clock D. Single hop only; deeper shapes belong to other
    // rules. A reset mux on the far D is part of that flop, not a gate.
    pub fn hasInterStageComb(t: *const Table, mod: *const ir.types.Module, head: usize) ?usize {
        const c = mod.cells[head];
        const q = portBits(c, "Q") orelse return null;
        if (q.len != 1 or q[0] != .sig) return null;
        const head_clock = (t.domains.get(head) orelse return null).name;
        const loads = mod.loads_of.get(q[0].sig) orelse return null;
        for (loads.items) |loc| {
            const ci = loc.cell orelse continue;
            const m = mod.cells[ci];
            if (clock.cells.isSequential(m.type)) continue;
            const y = portBits(m, "Y") orelse continue;
            for (y) |yb| {
                if (yb != .sig) continue;
                const nxt = t.d_bit_to_flop.get(yb.sig) orelse continue;
                if (nxt == head) continue;
                const dom = t.domains.get(nxt) orelse continue;
                if (!std.mem.eql(u8, dom.name, head_clock)) continue;
                if (t.srst_data_bit_to_flop.get(q[0].sig)) |behind| {
                    if (behind == nxt) continue;
                }
                return nxt;
            }
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
        const d = portBits(c, "D") orelse return null;
        if (d.len == 0 or d[0] != .sig) return null;
        const drv = mod.driver_of.get(d[0].sig) orelse return null;
        const mci = drv.cell orelse return null;
        if (!std.mem.eql(u8, drv.port, "Y")) return null;
        const m = mod.cells[mci];
        if (!std.mem.eql(u8, m.type, "$mux")) return null;
        const y = portBits(m, "Y") orelse return null;
        const a = portBits(m, "A") orelse return null;
        const b = portBits(m, "B") orelse return null;
        if (y.len != d.len or a.len != d.len or b.len != d.len) return null;
        for (y, d) |yb, db| {
            if (yb != .sig or db != .sig or yb.sig != db.sig) return null;
        }
        for (y) |yb| {
            if (t.readers(mod, yb.sig) != 1) return null;
        }
        const a_const = allConst(a);
        const b_const = allConst(b);
        if (a_const == b_const) return null;
        return if (b_const) a else b;
    }

    // Effective depth of a packed shift register: D lanes are the
    // flop's own Q bits except exactly one external lane, followed
    // lane to lane while each tap stays single-reader. Anything else
    // (buses, gray counters, enables) is not this shape.
    fn packedDepth(t: *Table, mod: *const ir.types.Module, head: usize) error{OutOfMemory}!?Entry {
        const c = mod.cells[head];
        const q = portBits(c, "Q") orelse return null;
        const d = portBits(c, "D") orelse return null;
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
        const d = portBits(c, "D") orelse continue;
        const q = portBits(c, "Q") orelse continue;
        if (d.len != 1 or q.len != 1) continue;
        if (d[0] != .sig) continue;
        try d_bit_to_flop.put(alloc, d[0].sig, ci);
    }

    var t = Table{
        .alloc = alloc,
        .backing = backing,
        .domains = domains,
        .d_bit_to_flop = d_bit_to_flop,
        .srst_data_bit_to_flop = .{},
        .memo = .{},
    };
    // First flop wins a shared data bit, in cell order: a shared
    // bit has two readers anyway, so walkers reject it first.
    for (mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type)) continue;
        const d = portBits(c, "D") orelse continue;
        const q = portBits(c, "Q") orelse continue;
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

fn allConst(bits: []ir.bits.Bit) bool {
    for (bits) |b| if (b == .sig) return false;
    return true;
}

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
    }
    return null;
}
