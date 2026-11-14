// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const id = @import("id.zig");
const ir = @import("../ir.zig");
const sdc = @import("../sdc.zig");
const walkidx = @import("walkidx.zig");

pub const SinkClass = walkidx.SinkClass;
pub const sinkClass = walkidx.sinkClass;

pub const Kind = enum {
    flop_flop_bit,
    flop_flop_bus,
    port_flop,
    port_flop_untyped,
    port_flop_bus,
    flop_port,
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
    hop_count: u32,
    lanes: []Lane,
    instance_path: [][]const u8,
    src_loc: []const u8,
    dst_loc: []const u8,
};

pub const Report = struct {
    // Heap-owned, matching Module: copying a live arena orphans
    // later allocations from deinit (see ir/types.zig).
    backing: *std.heap.ArenaAllocator,
    // One pair arena per walk worker: hop paths borrow from
    // them, so they outlive the build like the backing does.
    parenas: []std.heap.ArenaAllocator,
    crossings: []Crossing,

    pub fn deinit(self: *Report) void {
        const parent = self.backing.child_allocator;
        for (self.parenas) |*pa| pa.deinit();
        parent.free(self.parenas);
        self.backing.deinit();
        parent.destroy(self.backing);
    }
};

const Source = struct {
    cell: ?usize,
    port: []const u8,
    bit: u32,
    lane: usize,
};

// One walked range: sources are independent (read-only index,
// private visit state and scratch), so threads split them.
// Pair order stays source order across the join, and the final
// id sort is total, so threaded output is byte-identical.
const Walked = struct {
    en: Enumerator,
    scratch: std.heap.ArenaAllocator,
    visit: walkidx.Visit,
    pairs: std.ArrayListUnmanaged(Pair) = .empty,
    parena: std.heap.ArenaAllocator,
    err: ?error{OutOfMemory} = null,

    fn run(w: *Walked, sources: []const Source) void {
        for (sources) |s| {
            w.en.walkFrom(s.cell, s.port, s.bit, s.lane, &w.pairs) catch |e| {
                w.err = e;
                return;
            };
        }
    }

    // Scratch and visit die after the walk; the pair arena
    // outlives the build (hop paths borrow it).
    fn deinitTransient(w: *Walked, parent: std.mem.Allocator) void {
        w.scratch.deinit();
        parent.free(w.visit.stamp);
        parent.free(w.visit.prev);
        parent.free(w.visit.via);
    }
};

// Chunk edges snap to cell boundaries: source-keyed ledger
// groups complete within one range, so per-range ledgers stay
// exact. Same pairs, same order; the walk subdivides ranges
// further, since ledger scope and walk units differ in size.
fn chunkRanges(sources: []const Source, out: [][2]usize) void {
    var lo: usize = 0;
    for (out, 0..) |*r, i| {
        var hi = sources.len * (i + 1) / out.len;
        if (i + 1 < out.len) {
            while (hi < sources.len and sameCell(sources[hi - 1], sources[hi])) hi += 1;
        } else hi = sources.len;
        r.* = .{ lo, hi };
        lo = hi;
    }
}

// Walked ranges in parallel, joined in range order. The pair
// arenas transfer to the caller; transients die in deinit.
fn walkRanges(
    parent: std.mem.Allocator,
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    clock_of: []?*const clock.trace.Domain,
    bit_domains: *const std.AutoHashMapUnmanaged(u32, clock.trace.Domain),
    widx: *const walkidx.Index,
    sources: []const Source,
    ranges: []const [2]usize,
    stream: bool,
) error{OutOfMemory}![]Walked {
    const ws = try tmp.alloc(Walked, ranges.len);
    // Setup errors free the finished prefix; later errors free
    // everything, since the walk borrows nothing unbuilt.
    var nvis: usize = 0;
    var setup_done = false;
    errdefer {
        const n = if (setup_done) ws.len else nvis;
        for (ws[0..n]) |*w| {
            w.deinitTransient(parent);
            w.parena.deinit();
        }
    }
    for (ws) |*w| {
        // Full literal: tmp.alloc leaves pairs/err undefined,
        // and field-by-field assignment never touches them.
        const pa = std.heap.ArenaAllocator.init(parent);
        const sc = std.heap.ArenaAllocator.init(parent);
        const vs = try widx.allocVisit(parent);
        w.* = .{ .en = undefined, .scratch = sc, .visit = vs, .parena = pa };
        w.en = .{
            .mod = mod,
            .model = model,
            .alloc = undefined,
            .pair_alloc = w.parena.allocator(),
            .scratch = &w.scratch,
            .clock_of = clock_of,
            .bit_domains = bit_domains,
            .idx = widx,
            .visit = &w.visit,
            .stream = stream,
        };
        nvis += 1;
    }
    setup_done = true;
    const RunArg = struct { w: *Walked, sources: []const Source };
    const runRange = struct {
        fn f(a: RunArg) void {
            a.w.run(a.sources);
        }
    }.f;
    if (ws.len == 1) {
        ws[0].run(sources[ranges[0][0]..ranges[0][1]]);
    } else {
        const threads = try tmp.alloc(std.Thread, ws.len);
        const args = try tmp.alloc(RunArg, ws.len);
        var live: usize = 0;
        for (ws, 0..) |*w, i| {
            args[i] = .{ .w = w, .sources = sources[ranges[i][0]..ranges[i][1]] };
            threads[i] = std.Thread.spawn(.{}, runRange, .{args[i]}) catch {
                // Thread sandboxes run inline instead: slower,
                // identical output, no failure to report.
                for (args[i..]) |a| a.w.run(a.sources);
                break;
            };
            live += 1;
        }
        for (threads[0..live]) |t| t.join();
    }
    for (ws) |w| if (w.err) |e| return e;
    return ws;
}

// Bit records plus bus groups. The build arena owns the
// crossings; transients die in build_alloc, never in the
// retained pair arenas they would bloat. Stream builds skip
// the id sort and the ids themselves: every consumer folds
// order-free, and the sort costs two-thirds of build time.
fn buildChunk(
    en: *Enumerator,
    build_alloc: std.mem.Allocator,
    pairs: []const Pair,
    alloc: std.mem.Allocator,
    stream: bool,
) error{OutOfMemory}![]Crossing {
    en.pair_alloc = build_alloc;
    var plist: std.ArrayListUnmanaged(Pair) = .{ .items = @constCast(pairs), .capacity = pairs.len, .pointer_stability = .{} };
    var out: std.ArrayListUnmanaged(Crossing) = .empty;
    // Presized: millions of pairs double the list into gigabytes
    // of retained arena slack; enumeration holds one vector.
    try out.ensureTotalCapacity(alloc, pairs.len);
    // Emit already applied keepPair; every pair here builds.
    for (plist.items) |pr| {
        try out.append(alloc, try en.buildCrossing(pr, null, stream));
    }
    try en.appendBusGroups(&plist, &out, stream);
    if (stream) return out.items;
    // Argsort indices, then permute in place: a Crossing spans
    // hundreds of bytes, so a gathered copy doubles a vector
    // already worth gigabytes. IDs are unique, so the order is
    // total and the permutation applies exactly once per cycle.
    const order = try alloc.alloc(u32, out.items.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, out.items, struct {
        fn less(xs: []Crossing, a: u32, b: u32) bool {
            return std.mem.lessThan(u8, xs[a].id, xs[b].id);
        }
    }.less);
    const seen = try alloc.alloc(u8, (out.items.len + 7) / 8);
    @memset(seen, 0);
    var tmpc: Crossing = undefined;
    var started = false;
    for (order, 0..) |_, j| {
        if (seen[j / 8] & (@as(u8, 1) << @intCast(j % 8)) != 0) continue;
        var cur = j;
        tmpc = out.items[j];
        started = true;
        while (started or cur != j) {
            started = false;
            const nxt = order[cur];
            seen[cur / 8] |= @as(u8, 1) << @intCast(cur % 8);
            if (nxt == j) {
                out.items[cur] = tmpc;
                break;
            }
            out.items[cur] = out.items[nxt];
            cur = nxt;
        }
    }
    return out.items;
}

// One cell feeds one ledger range: source-keyed rules keep
// exact per-source sets, so a split cell would slice them.
// Ports group by name; mixed cell/port never shares a cell.
fn sameCell(a: Source, b: Source) bool {
    if ((a.cell == null) != (b.cell == null)) return false;
    if (a.cell) |ac| return ac == b.cell.?;
    return std.mem.eql(u8, a.port, b.port);
}

// One run feeds one walk slice: bus lanes share a cell and
// port, so a split run would fragment their group record.
// Runs split cells by port; mixed never shares a run.
fn sameRun(a: Source, b: Source) bool {
    if ((a.cell == null) != (b.cell == null)) return false;
    if (a.cell) |ac| {
        if (ac != b.cell.?) return false;
        return std.mem.eql(u8, a.port, b.port);
    }
    return std.mem.eql(u8, a.port, b.port);
}

// Walk inputs shared by every range: the flop clock map, the
// resolved fanout index, and the source list. keep outlives the
// whole enumeration; tmp dies with it.
const Prepared = struct {
    // Dense per-cell flop domains: the walk and the build ask
    // per pair, and a hash per pair costs more than the ask.
    clock_of: []?*const clock.trace.Domain,
    widx: walkidx.Index,
    sources: []Source,
};

fn prepare(
    keep: std.mem.Allocator,
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    clock_asg: *const clock.trace.Assignment,
    model: *const sdc.model.Model,
) error{OutOfMemory}!Prepared {
    const clock_of = try keep.alloc(?*const clock.trace.Domain, mod.cells.len);
    @memset(clock_of, null);
    for (clock_asg.flops) |f| {
        const slot = try keep.create(clock.trace.Domain);
        slot.* = f.domain;
        clock_of[f.cell] = slot;
    }

    const controls = try keep.dupe(clock.trace.ControlPin, clock_asg.controls);
    std.mem.sort(clock.trace.ControlPin, controls, {}, struct {
        fn less(_: void, a: clock.trace.ControlPin, b: clock.trace.ControlPin) bool {
            if (a.cell != b.cell) return a.cell < b.cell;
            return std.mem.lessThan(u8, a.pin, b.pin);
        }
    }.less);
    const widx = try walkidx.Index.build(tmp, mod, controls, model);

    var srclist: std.ArrayListUnmanaged(Source) = .empty;
    for (mod.cells, 0..) |c, ci| {
        if (clock.cells.isSequential(c.type)) {
            if (c.portBits("Q")) |q| {
                for (q, 0..) |b, lane| {
                    if (b != .sig) continue;
                    try srclist.append(tmp, .{ .cell = ci, .port = "Q", .bit = b.sig, .lane = lane });
                }
            }
        } else if (clock.cells.isMemRead(c.type)) {
            if (c.portBits("DATA")) |d| {
                for (d, 0..) |b, lane| {
                    if (b != .sig) continue;
                    try srclist.append(tmp, .{ .cell = ci, .port = "DATA", .bit = b.sig, .lane = lane });
                }
            }
        } else if (c.blackbox) {
            for (c.ports) |p| {
                if (p.direction == .input) continue;
                for (p.bits, 0..) |b, lane| {
                    if (b != .sig) continue;
                    try srclist.append(tmp, .{ .cell = ci, .port = p.name, .bit = b.sig, .lane = lane });
                }
            }
        }
    }
    for (mod.ports) |p| {
        if (p.direction == .output) continue;
        for (p.bits, 0..) |b, lane| {
            if (b != .sig) continue;
            try srclist.append(tmp, .{ .cell = null, .port = p.name, .bit = b.sig, .lane = lane });
        }
    }
    return .{ .clock_of = clock_of, .widx = widx, .sources = srclist.items };
}

// Cost: O(sources × cone) visits over a resolved index, each
// visit array-indexed, split across worker threads; output
// pruned to async, unknown, and control arrivals before hashing.
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

    var idx_arena = std.heap.ArenaAllocator.init(parent);
    defer idx_arena.deinit();
    const tmp = idx_arena.allocator();
    const prep = try prepare(alloc, tmp, mod, clock_asg, model);
    const sources = prep.sources;

    const nchunks = @max(@min(sources.len, std.Thread.getCpuCount() catch 1), 1);
    const ranges = try tmp.alloc([2]usize, nchunks);
    chunkRanges(sources, ranges);
    const walked = try walkRanges(parent, tmp, mod, model, prep.clock_of, &clock_asg.bit_domains, &prep.widx, sources, ranges, false);
    defer {
        for (walked) |*w| w.deinitTransient(parent);
    }

    // Concat in chunk order: source order survives the join,
    // so downstream sees the single-threaded sequence.
    // Raw pairs die after the build: only crossings survive, so
    // the pair structs must not ride the retained backing arena.
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    var total: usize = 0;
    for (walked) |w| total += w.pairs.items.len;
    try pairs.ensureTotalCapacity(walked[0].parena.allocator(), total);
    for (walked) |w| try pairs.appendSlice(walked[0].parena.allocator(), w.pairs.items);

    // Pair arenas outlive the build (hop paths borrow them);
    // the report owns them, so only errors clean up here.
    const parenas = try parent.alloc(std.heap.ArenaAllocator, walked.len);
    errdefer parent.free(parenas);
    for (walked, 0..) |*w, i| parenas[i] = w.parena;
    errdefer {
        for (parenas) |*pa| pa.deinit();
    }

    // Build-phase transients (bus-group candidates) die here,
    // not in the retained pair arenas they would bloat.
    var build_tmp = std.heap.ArenaAllocator.init(parent);
    defer build_tmp.deinit();
    var en = walked[0].en;
    en.alloc = alloc;
    const sorted = try buildChunk(&en, build_tmp.allocator(), pairs.items, alloc, false);
    return .{ .backing = backing, .parenas = parenas, .crossings = sorted };
}

// One consumable unit: the pair count plus the crossings
// built from them. Both die with the callback's return.
// range_last marks the ledger range's final sub-batch, so
// per-range accumulators know their groups are complete.
pub const Batch = struct {
    pairs: usize,
    crossings: []Crossing,
    range_last: bool,
};

// One pair slice built and consumed, then freed: crossings
// die with the call, so the callback must copy what it keeps.
// A null selection takes all pairs without a gather copy.
fn runSub(
    parent: std.mem.Allocator,
    en: *Enumerator,
    all_pairs: []const Pair,
    sel: ?[]const usize,
    range_last: bool,
    bctx: anytype,
    comptime onBatch: fn (@TypeOf(bctx), Batch) error{OutOfMemory}!void,
) error{OutOfMemory}!void {
    var chunk_arena = std.heap.ArenaAllocator.init(parent);
    defer chunk_arena.deinit();
    var build_tmp = std.heap.ArenaAllocator.init(parent);
    defer build_tmp.deinit();
    const pairs = if (sel) |s| blk: {
        const sub = try chunk_arena.allocator().alloc(Pair, s.len);
        for (s, 0..) |k, n| sub[n] = all_pairs[k];
        break :blk sub;
    } else all_pairs;
    en.alloc = chunk_arena.allocator();
    const crossings = try buildChunk(en, build_tmp.allocator(), pairs, chunk_arena.allocator(), true);
    try onBatch(bctx, .{ .pairs = pairs.len, .crossings = crossings, .range_last = range_last });
}

// One walked range built and consumed, then freed. Ranges past
// the pair budget split by destination cell: bus runs share one
// dst cell, so they survive the split whole, and every rule is
// per-crossing, per-dst, or a global ledger across sub-batches.
fn runOne(
    parent: std.mem.Allocator,
    w: *Walked,
    pair_budget: usize,
    range_last: bool,
    bctx: anytype,
    comptime onBatch: fn (@TypeOf(bctx), Batch) error{OutOfMemory}!void,
) error{OutOfMemory}!void {
    defer {
        w.deinitTransient(parent);
        w.parena.deinit();
    }
    if (w.pairs.items.len <= pair_budget) {
        return runSub(parent, &w.en, w.pairs.items, null, range_last, bctx, onBatch);
    }
    var idx_arena = std.heap.ArenaAllocator.init(parent);
    defer idx_arena.deinit();
    const idx = try idx_arena.allocator().alloc(usize, w.pairs.items.len);
    for (idx, 0..) |*v, i| v.* = i;
    std.mem.sort(usize, idx, w.pairs.items, struct {
        fn less(ps: []Pair, a: usize, b: usize) bool {
            const da = ps[a].dst_cell;
            const db = ps[b].dst_cell;
            if ((da == null) != (db == null)) return da == null;
            if (da) |va| return va < db.?;
            return false;
        }
    }.less);
    var i: usize = 0;
    while (i < idx.len) {
        var j = i + 1;
        while (j < idx.len and w.pairs.items[idx[j]].dst_cell == w.pairs.items[idx[i]].dst_cell) : (j += 1) {}
        try runSub(parent, &w.en, w.pairs.items, idx[i..j], range_last and j == idx.len, bctx, onBatch);
        i = j;
    }
}

fn runGroup(
    parent: std.mem.Allocator,
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    prep: *const Prepared,
    clock_asg: *const clock.trace.Assignment,
    slices: []const [2]usize,
    ends: []const bool,
    pair_budget: usize,
    bctx: anytype,
    comptime onBatch: fn (@TypeOf(bctx), Batch) error{OutOfMemory}!void,
) error{OutOfMemory}!void {
    const walked = try walkRanges(parent, tmp, mod, model, prep.clock_of, &clock_asg.bit_domains, &prep.widx, prep.sources, slices, true);
    var done: usize = 0;
    errdefer {
        for (walked[done..]) |*w| {
            w.deinitTransient(parent);
            w.parena.deinit();
        }
    }
    for (walked, ends) |*w, last| {
        try runOne(parent, w, pair_budget, last, bctx, onBatch);
        done += 1;
    }
}

// Chunked enumeration for designs no report can hold: walk
// slices run in thread-sized groups, each builds its crossings,
// the callback consumes them, and only findings survive. Slices
// past the pair budget split by destination cell, so peak memory
// is one group of pairs plus one budget of crossings, bounded
// for any input no matter how fanout concentrates.
// Cost: same O(sources × cone) walk as enumerate; rules run
// once per batch, range ledgers finish at range end.
pub fn streamBatches(
    parent: std.mem.Allocator,
    mod: *const ir.types.Module,
    clock_asg: *const clock.trace.Assignment,
    model: *const sdc.model.Model,
    chunk_sources: usize,
    pair_budget: usize,
    bctx: anytype,
    comptime onBatch: fn (@TypeOf(bctx), Batch) error{OutOfMemory}!void,
) error{OutOfMemory}!void {
    var setup_arena = std.heap.ArenaAllocator.init(parent);
    defer setup_arena.deinit();
    const keep = setup_arena.allocator();
    var idx_arena = std.heap.ArenaAllocator.init(parent);
    defer idx_arena.deinit();
    const tmp = idx_arena.allocator();
    const prep = try prepare(keep, tmp, mod, clock_asg, model);
    const sources = prep.sources;

    const per = @max(chunk_sources, 1);
    const nchunks = @max((sources.len + per - 1) / per, 1);
    const ranges = try tmp.alloc([2]usize, nchunks);
    chunkRanges(sources, ranges);
    // Walk slices subdivide ledger ranges: a wide cell owns one
    // exact range, but the walk materializes per slice, so peak
    // memory never follows the widest cell. Slices snap to runs,
    // since bus lanes share a run and split lanes lose their
    // group record; only ranges carry ledger scope, flagged last.
    var nslices: usize = 0;
    for (ranges) |r| {
        // Snapping overshoots into empty ranges past long cells;
        // they walk nothing and finish nothing, so they cut out.
        if (r[0] >= r[1]) continue;
        var lo = r[0];
        while (lo < r[1]) {
            var hi = @min(lo + per, r[1]);
            while (hi < r[1] and sameRun(sources[hi - 1], sources[hi])) hi += 1;
            nslices += 1;
            lo = hi;
        }
    }
    const slices = try tmp.alloc([2]usize, nslices);
    const ends = try tmp.alloc(bool, nslices);
    var si: usize = 0;
    for (ranges) |r| {
        if (r[0] >= r[1]) continue;
        var lo = r[0];
        while (lo < r[1]) {
            var hi = @min(lo + per, r[1]);
            while (hi < r[1] and sameRun(sources[hi - 1], sources[hi])) hi += 1;
            slices[si] = .{ lo, hi };
            ends[si] = hi == r[1];
            si += 1;
            lo = hi;
        }
    }
    const group = @max(@min(slices.len, std.Thread.getCpuCount() catch 1), 1);
    const budget = @max(pair_budget, 1);
    var gi: usize = 0;
    while (gi < slices.len) {
        const gj = @min(gi + group, slices.len);
        try runGroup(parent, tmp, mod, model, &prep, clock_asg, slices[gi..gj], ends[gi..gj], budget, bctx, onBatch);
        gi = gj;
    }
}

// Both cells clocked by the identical bit set: same net,
// same edge, synchronous by physics rather than by name.
fn sameClockNet(mod: *const ir.types.Module, a: usize, b: usize) bool {
    if (samePinBits(mod.cells[a], mod.cells[b], "CLK")) return true;
    if (samePinBits(mod.cells[a], mod.cells[b], "G")) return true;
    if (!clock.cells.isLatch(mod.cells[a].type)) return false;
    if (!clock.cells.isLatch(mod.cells[b].type)) return false;
    return samePinBits(mod.cells[a], mod.cells[b], "EN");
}

// Blackbox outputs and async memory reads leave without a
// clock, so a shared clock net says nothing about them.
fn opaqueSource(c: ir.types.Cell) bool {
    if (c.blackbox) return true;
    return clock.cells.isMemRead(c.type) and !readEnabled(c);
}

fn samePinBits(a: ir.types.Cell, b: ir.types.Cell, pin: []const u8) bool {
    const ca = a.portBits(pin) orelse return false;
    const cb = b.portBits(pin) orelse return false;
    if (ca.len == 0 or ca.len != cb.len) return false;
    for (ca, cb) |x, y| {
        if (x != .sig or y != .sig or x.sig != y.sig) return false;
    }
    return true;
}

const Pair = struct {
    src_cell: ?usize,
    src_port: []const u8,
    src_bit: u32,
    src_lane: usize,
    dst_cell: ?usize,
    dst_pin: []const u8,
    dst_bit: u32,
    dst_lane: usize,
    dst_class: ?SinkClass,
    dst_control: bool,
    hops: []usize,
    hops_len: u32 = 0,
};

const Enumerator = struct {
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    alloc: std.mem.Allocator,
    pair_alloc: std.mem.Allocator,
    scratch: *std.heap.ArenaAllocator,
    clock_of: []?*const clock.trace.Domain,
    bit_domains: *const std.AutoHashMapUnmanaged(u32, clock.trace.Domain),
    idx: *const walkidx.Index,
    visit: *walkidx.Visit,
    // Stream walks count hops instead of storing paths: paths
    // cost length per pair, and broadcast regions hold more
    // pairs than memory holds paths. Nothing streamed reads
    // names, only the count CDC-003 needs.
    stream: bool,

    fn walkFrom(
        en: *Enumerator,
        src_cell: ?usize,
        src_port: []const u8,
        src_bit: u32,
        src_lane: usize,
        pairs: *std.ArrayListUnmanaged(Pair),
    ) error{OutOfMemory}!void {
        // Walk state resets per source, bounding transient memory to
        // one cone; the walk itself costs O(cone) time, visited-guarded.
        // Visits index the resolved fanout: loads on null cells,
        // blackboxes, and opaque memories never entered it, matching
        // the three skips the hash walk applied per visit.
        _ = en.scratch.reset(.retain_capacity);
        const tmp = en.scratch.allocator();
        const idx = en.idx;
        const vs = en.visit;
        vs.nextGen();
        const gen = vs.gen;
        vs.stamp[src_bit] = gen;
        vs.prev[src_bit] = walkidx.Index.none;
        vs.via[src_bit] = walkidx.Index.none;
        var queue: std.ArrayListUnmanaged(u32) = .empty;
        var head: usize = 0;
        try queue.append(tmp, src_bit);
        while (head < queue.items.len) {
            const b = queue.items[head];
            head += 1;
            for (idx.loads(b)) |ld| {
                // Typed output ports end the cone with a pair. Port
                // sources skip: port-to-port pairs have no consumer yet.
                if (ld.cell == null) {
                    if (src_cell == null) continue;
                    try en.emit(pairs, src_cell, src_port, src_bit, src_lane, null, ld.pin, b, ld.lane, null, false);
                    continue;
                }
                const lc = ld.cell.?;
                // Control arrivals emit, then keep walking: the value
                // still reaches the clock, so the glitch path survives.
                if (ld.control) {
                    try en.emit(pairs, src_cell, src_port, src_bit, src_lane, lc, ld.pin, b, ld.lane, null, true);
                }
                if (ld.sink) |cls| {
                    // Same-cell pairs are self-feedback, never
                    // crossings: a flop's Q reaching its own D
                    // through comb is a counter, not a CDC.
                    if (src_cell != null and src_cell.? == lc) continue;
                    try en.emit(pairs, src_cell, src_port, src_bit, src_lane, lc, ld.pin, b, ld.lane, cls, false);
                } else if (idx.cells[lc].seq_or_memclock) {
                    // Unclassified sequential inputs end the walk:
                    // boundaries cut, never go transparent.
                    continue;
                } else {
                    try en.propagate(lc, ld, b, gen, &queue, tmp);
                }
            }
        }
    }

    fn emit(
        en: *Enumerator,
        pairs: *std.ArrayListUnmanaged(Pair),
        src_cell: ?usize,
        src_port: []const u8,
        src_bit: u32,
        src_lane: usize,
        ci: ?usize,
        pin: []const u8,
        b: u32,
        dst_lane: usize,
        cls: ?SinkClass,
        control: bool,
    ) error{OutOfMemory}!void {
        // Sync data pairs die before hop reconstruction: discovery
        // emits millions and no rule consumes them. Unknown pairs
        // keep endpoints but no path: CDC-025 aggregates them per
        // source, and no path rule may read them. Emit stays
        // O(path) for kept known pairs, O(1) for the rest.
        var pr = Pair{
            .src_cell = src_cell,
            .src_port = src_port,
            .src_bit = src_bit,
            .src_lane = src_lane,
            .dst_cell = ci,
            .dst_pin = pin,
            .dst_bit = b,
            .dst_lane = dst_lane,
            .dst_class = cls,
            .dst_control = control,
            .hops = &.{},
        };
        if (!en.keepPair(pr)) return;
        if (en.knownPair(pr)) {
            if (en.stream) {
                pr.hops_len = en.countHops(b);
            } else {
                pr.hops = try en.reconstruct(b);
                pr.hops_len = @intCast(pr.hops.len);
            }
        }
        try pairs.append(en.pair_alloc, pr);
    }

    fn countHops(en: *Enumerator, dst: u32) u32 {
        const vs = en.visit;
        var n: u32 = 0;
        var cur: u32 = dst;
        while (cur != walkidx.Index.none) {
            if (vs.via[cur] != walkidx.Index.none) n += 1;
            cur = vs.prev[cur];
        }
        return n;
    }

    // Both ends resolve to real clocks: the same predicate the
    // clock labels use, so a stored path always has two anchors.
    // The dispatcher additionally routes untyped-kind pairs past
    // per-pair rules; their paths serve the check_all owners.
    fn knownPair(en: *Enumerator, pr: Pair) bool {
        if (pr.dst_cell == null) {
            // Port destinations resolve through SDC typing, never
            // the flop table; the walk only emits typed ports.
            if (en.typedClock(pr.dst_pin) == null) return false;
        } else {
            const dd = en.dstDomain(pr) orelse return false;
            if (std.mem.eql(u8, dd.name, "unknown")) return false;
        }
        if (pr.src_cell) |_| {
            const sd = en.srcDomain(pr) orelse return false;
            if (std.mem.eql(u8, sd.name, "unknown")) return false;
        } else if (en.srcClockName(pr.src_port) == null) {
            return false;
        }
        return true;
    }

    // Bitwise cells propagate lane-to-lane; fully connected would
    // invent crossings across wide buses. Reductions stay connected.
    fn propagate(
        en: *Enumerator,
        ci: usize,
        ld: walkidx.Load,
        bit: u32,
        gen: u32,
        queue: *std.ArrayListUnmanaged(u32),
        tmp: std.mem.Allocator,
    ) error{OutOfMemory}!void {
        const info = en.idx.cells[ci];
        const c = en.mod.cells[ci];
        for (c.ports) |p| {
            if (p.direction != .output or p.bits.len == 0) continue;
            if (outLaneFast(info, ld, p.bits.len)) |ol| {
                try en.visitBit(p.bits[ol], bit, ci, gen, queue, tmp);
            } else {
                for (p.bits) |ob| try en.visitBit(ob, bit, ci, gen, queue, tmp);
            }
        }
    }

    fn visitBit(
        en: *Enumerator,
        ob: ir.bits.Bit,
        from: u32,
        via: usize,
        gen: u32,
        queue: *std.ArrayListUnmanaged(u32),
        tmp: std.mem.Allocator,
    ) error{OutOfMemory}!void {
        if (ob != .sig) return;
        const vs = en.visit;
        if (vs.stamp[ob.sig] == gen) return;
        vs.stamp[ob.sig] = gen;
        vs.prev[ob.sig] = from;
        vs.via[ob.sig] = @intCast(via);
        try queue.append(tmp, ob.sig);
    }

    fn reconstruct(en: *Enumerator, dst: u32) error{OutOfMemory}![]usize {
        // Hop paths ride the worker's pair arena: the shared
        // backing is untouchable mid-walk, and the report owns
        // the pair arenas, so paths outlive the build either way.
        const vs = en.visit;
        var rev: std.ArrayListUnmanaged(usize) = .empty;
        var cur: u32 = dst;
        while (cur != walkidx.Index.none) {
            const v = vs.via[cur];
            if (v != walkidx.Index.none) try rev.append(en.pair_alloc, v);
            cur = vs.prev[cur];
        }
        std.mem.reverse(usize, rev.items);
        return rev.toOwnedSlice(en.pair_alloc);
    }

    // Synchronous data pairs are not crossings: no rule consumes
    // them, and real cones emit millions. Controls and unknowns stay.
    fn keepPair(en: *Enumerator, pr: Pair) bool {
        if (pr.dst_control or pr.dst_class == .clk) return true;
        return en.asyncFor(pr);
    }

    fn buildCrossing(en: *Enumerator, pr: Pair, kind_override: ?Kind, stream: bool) error{OutOfMemory}!Crossing {
        const kind: Kind = kind_override orelse if (pr.dst_control)
            .clock_control
        else if (pr.dst_class == .clk)
            .clock_sink
        else if (pr.dst_cell == null)
            .flop_port
        else if (pr.src_cell == null)
            if (en.typedClock(pr.src_port)) |_| .port_flop else .port_flop_untyped
        else
            // Blackbox outputs ride flop-flop-bit: the endpoint
            // cell type identifies them, and rules check it.
            .flop_flop_bit;
        const src_clk = try en.srcClock(pr);
        const dst_clk = try en.dstClock(pr);
        // Stream builds skip ids: no rule reads them, and the
        // hash plus endpoint renders cost per crossing.
        const ident: []const u8 = if (stream) &.{} else blk: {
            const src_name = try renderEndpoint(en.alloc, en.mod, pr.src_cell, pr.src_port, pr.src_bit);
            defer en.alloc.free(src_name);
            const dst_name = try renderEndpoint(en.alloc, en.mod, pr.dst_cell, pr.dst_pin, pr.dst_bit);
            defer en.alloc.free(dst_name);
            const h = id.compute(@tagName(kind), src_name, dst_name, src_clk, dst_clk);
            break :blk try en.alloc.dupe(u8, &h);
        };
        return .{
            .id = ident,
            .hop_count = pr.hops_len,
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
            // Ports carry no hierarchy: nothing reads the path, and
            // inventing one would forge matchable ancestry.
            .instance_path = if (pr.dst_cell) |dc| try en.dupePath(en.mod.cells[dc]) else &.{},
            .src_loc = try en.cellLoc(pr.src_cell),
            .dst_loc = try en.cellLoc(pr.dst_cell),
        };
    }

    // Bus groups cut from key-sorted runs: pairs sharing (src
    // cell-or-port + pin, dst cell + pin) gain one bus record
    // beside their bit records. Ports group by port identity.
    fn appendBusGroups(
        en: *Enumerator,
        pairs: *const std.ArrayListUnmanaged(Pair),
        out: *std.ArrayListUnmanaged(Crossing),
        stream: bool,
    ) error{OutOfMemory}!void {
        var cand: std.ArrayListUnmanaged(usize) = .empty;
        for (pairs.items, 0..) |pr, i| {
            if (pr.src_cell) |sc| {
                if (en.mod.cells[sc].blackbox) continue;
            }
            // Port destinations group by bit only: bus keys anchor
            // on cells, and port buses have no rule consumer yet.
            if (pr.dst_cell == null) continue;
            if (pr.dst_control or pr.dst_class == .clk) continue;
            if (!en.asyncFor(pr)) continue;
            try cand.append(en.pair_alloc, i);
        }
        std.mem.sort(usize, cand.items, pairs, struct {
            fn less(ps: *const std.ArrayListUnmanaged(Pair), a: usize, b: usize) bool {
                const pa = ps.items[a];
                const pb = ps.items[b];
                if ((pa.src_cell == null) != (pb.src_cell == null)) return pa.src_cell == null;
                if (pa.src_cell) |sa| {
                    if (sa != pb.src_cell.?) return sa < pb.src_cell.?;
                }
                if (!std.mem.eql(u8, pa.src_port, pb.src_port)) return std.mem.lessThan(u8, pa.src_port, pb.src_port);
                if ((pa.dst_cell == null) != (pb.dst_cell == null)) return pa.dst_cell == null;
                if (pa.dst_cell) |da| {
                    if (da != pb.dst_cell.?) return da < pb.dst_cell.?;
                }
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
                const bkind: Kind = if (pairs.items[run[0]].src_cell == null) .port_flop_bus else .flop_flop_bus;
                var bus = try en.buildCrossing(pairs.items[run[0]], bkind, stream);
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
    fn clockAt(en: *Enumerator, cell: usize) ?clock.trace.Domain {
        if (cell >= en.clock_of.len) return null;
        return if (en.clock_of[cell]) |d| d.* else null;
    }

    fn dstDomain(en: *Enumerator, pr: Pair) ?clock.trace.Domain {
        // Port destinations have no flop row; typedClock names
        // their domain, and callers branch before asking here.
        if (pr.dst_cell == null) return null;
        const dc = pr.dst_cell.?;
        if (pr.dst_control) return en.controlOutDomain(dc);
        if (clock.cells.isMemoryClock(en.mod.cells[dc].type)) return en.memClockDomain(dc);
        return en.clockAt(dc);
    }

    fn srcDomain(en: *Enumerator, pr: Pair) ?clock.trace.Domain {
        const ci = pr.src_cell orelse return null;
        if (en.mod.cells[ci].blackbox) return null;
        if (clock.cells.isMemRead(en.mod.cells[ci].type)) {
            if (!readEnabled(en.mod.cells[ci])) return null;
            return en.memClockDomain(ci);
        }
        return en.clockAt(ci);
    }

    fn controlOutDomain(en: *Enumerator, ci: usize) ?clock.trace.Domain {
        const y = en.mod.cells[ci].portBits("Y") orelse return null;
        for (y) |b| {
            if (b != .sig) continue;
            if (en.bit_domains.get(b.sig)) |d| return d;
        }
        return null;
    }

    fn memClockDomain(en: *Enumerator, ci: usize) ?clock.trace.Domain {
        const clk = en.mod.cells[ci].portBits("CLK") orelse return null;
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
        if (pr.dst_cell == null) {
            // Untyped fallback labels the port: a port: destination
            // is clocked-but-undeclared, never CDC-025 unknown.
            if (en.typedClock(pr.dst_pin)) |c| return en.alloc.dupe(u8, c);
            return std.fmt.allocPrint(en.alloc, "port:{s}", .{pr.dst_pin});
        }
        if (en.dstDomain(pr)) |d| return en.alloc.dupe(u8, d.name);
        return en.alloc.dupe(u8, "unknown");
    }

    // Async when any leg pair is async: a muxed clock is only as
    // synchronous as its least synchronous leg. Unknown forces true.
    fn asyncFor(en: *Enumerator, pr: Pair) bool {
        // Same net beats every doubt, unknown included: one wire
        // is one edge. Opaque sources and port ends skip the guard.
        if (pr.src_cell) |sc| {
            if (pr.dst_cell) |dc| {
                if (!opaqueSource(en.mod.cells[sc]) and sameClockNet(en.mod, sc, dc)) return false;
            }
        }
        if (pr.dst_cell == null) {
            const dst_name = en.typedClock(pr.dst_pin) orelse return true;
            if (pr.src_cell) |_| {
                const src = en.srcDomain(pr) orelse return true;
                if (std.mem.eql(u8, src.name, "unknown")) return true;
                for (src.legs) |sl| {
                    if (en.model.areAsync(sl, dst_name)) return true;
                }
                return false;
            }
            const src_name = en.srcClockName(pr.src_port) orelse return true;
            return en.model.areAsync(src_name, dst_name);
        }
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
fn outLaneFast(info: walkidx.CellInfo, ld: walkidx.Load, out_len: usize) ?usize {
    if (ld.pin_ctl) return null;
    if (!info.parallel) return null;
    if (info.pmux and ld.pin_b) return ld.lane % out_len;
    if (ld.lane < out_len) return ld.lane;
    return null;
}

fn sameBusKey(a: Pair, b: Pair) bool {
    if ((a.src_cell == null) != (b.src_cell == null)) return false;
    if (a.src_cell) |sa| {
        if (sa != b.src_cell.?) return false;
    }
    if ((a.dst_cell == null) != (b.dst_cell == null)) return false;
    if (a.dst_cell) |da| {
        if (da != b.dst_cell.?) return false;
    }
    return std.mem.eql(u8, a.src_port, b.src_port) and std.mem.eql(u8, a.dst_pin, b.dst_pin);
}
