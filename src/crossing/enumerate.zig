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

// One walk worker: sources are independent (read-only index,
// private visit state and scratch), so threads split them.
// Pair order stays source order across the join, and the final
// id sort is total, so threaded output is byte-identical.
const Worker = struct {
    en: Enumerator,
    scratch: std.heap.ArenaAllocator,
    visit: walkidx.Visit,
    sources: []const Source,
    pairs: std.ArrayListUnmanaged(Pair) = .empty,
    err: ?error{OutOfMemory} = null,

    fn run(w: *Worker) void {
        for (w.sources) |s| {
            w.en.walkFrom(s.cell, s.port, s.bit, s.lane, &w.pairs) catch |e| {
                w.err = e;
                return;
            };
        }
    }
};

// One run feeds one chunk: cells group across their ports,
// ports group by name. Mixed cell/port never shares a run.
fn sameRun(a: Source, b: Source) bool {
    if ((a.cell == null) != (b.cell == null)) return false;
    if (a.cell) |ac| return ac == b.cell.?;
    return std.mem.eql(u8, a.port, b.port);
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

    var clock_of = std.AutoHashMapUnmanaged(usize, clock.trace.Domain){};
    for (clock_asg.flops) |f| try clock_of.put(alloc, f.cell, f.domain);

    const controls = try alloc.dupe(clock.trace.ControlPin, clock_asg.controls);
    std.mem.sort(clock.trace.ControlPin, controls, {}, struct {
        fn less(_: void, a: clock.trace.ControlPin, b: clock.trace.ControlPin) bool {
            if (a.cell != b.cell) return a.cell < b.cell;
            return std.mem.lessThan(u8, a.pin, b.pin);
        }
    }.less);
    var idx_arena = std.heap.ArenaAllocator.init(parent);
    defer idx_arena.deinit();
    const tmp = idx_arena.allocator();
    const widx = try walkidx.Index.build(tmp, mod, controls);

    var srclist: std.ArrayListUnmanaged(Source) = .empty;
    for (mod.cells, 0..) |c, ci| {
        if (clock.cells.isSequential(c.type)) {
            if (portBits(c, "Q")) |q| {
                for (q, 0..) |b, lane| {
                    if (b != .sig) continue;
                    try srclist.append(tmp, .{ .cell = ci, .port = "Q", .bit = b.sig, .lane = lane });
                }
            }
        } else if (clock.cells.isMemRead(c.type)) {
            if (portBits(c, "DATA")) |d| {
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
    const sources = srclist.items;

    // Pair arenas outlive the build (hop paths borrow them);
    // the report owns them, so only errors clean up here.
    const nworkers = @min(sources.len, std.Thread.getCpuCount() catch 1);
    const parenas = try parent.alloc(std.heap.ArenaAllocator, @max(nworkers, 1));
    errdefer parent.free(parenas);
    for (parenas) |*pa| pa.* = std.heap.ArenaAllocator.init(parent);
    errdefer {
        for (parenas) |*pa| pa.deinit();
    }
    // Visit allocation can fail mid-loop: the block errdefer
    // frees exactly the finished prefix and dies with the block,
    // so later errors never double-free against the full defer.
    const workers = blk: {
        const ws = try tmp.alloc(Worker, @max(nworkers, 1));
        var nvis: usize = 0;
        errdefer {
            for (ws[0..nvis]) |*w| {
                w.scratch.deinit();
                parent.free(w.visit.stamp);
                parent.free(w.visit.prev);
                parent.free(w.visit.via);
            }
        }
        // Chunk edges snap to source runs (one cell, one port):
        // batch-scoped rules group by source, so a split run
        // would slice their groups. Same pairs, same order.
        var lo: usize = 0;
        for (ws, 0..) |*w, i| {
            var hi = sources.len * (i + 1) / ws.len;
            if (i + 1 < ws.len) {
                while (hi < sources.len and sameRun(sources[hi - 1], sources[hi])) hi += 1;
            } else hi = sources.len;
            w.* = .{
                .en = .{
                    .mod = mod,
                    .model = model,
                    .alloc = alloc,
                    .pair_alloc = parenas[i].allocator(),
                    .scratch = undefined,
                    .clock_of = &clock_of,
                    .bit_domains = &clock_asg.bit_domains,
                    .idx = &widx,
                    .visit = undefined,
                },
                .scratch = std.heap.ArenaAllocator.init(parent),
                .visit = try widx.allocVisit(parent),
                .sources = sources[lo..hi],
            };
            w.en.scratch = &w.scratch;
            w.en.visit = &w.visit;
            nvis += 1;
            lo = hi;
        }
        break :blk ws;
    };
    defer {
        for (workers) |*w| {
            w.scratch.deinit();
            parent.free(w.visit.stamp);
            parent.free(w.visit.prev);
            parent.free(w.visit.via);
        }
    }
    if (workers.len == 1) {
        workers[0].run();
    } else {
        const threads = try tmp.alloc(std.Thread, workers.len);
        var live: usize = 0;
        for (workers, 0..) |*w, i| {
            threads[i] = std.Thread.spawn(.{}, Worker.run, .{w}) catch {
                // Thread sandboxes run inline instead: slower,
                // identical output, no failure to report.
                for (workers[i..]) |*rest| rest.run();
                break;
            };
            live += 1;
        }
        for (threads[0..live]) |t| t.join();
    }
    for (workers) |w| if (w.err) |e| return e;

    // Concat in chunk order: source order survives the join,
    // so downstream sees the single-threaded sequence.
    // Raw pairs die after the build: only crossings survive, so
    // the pair structs must not ride the retained backing arena.
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    var total: usize = 0;
    for (workers) |w| total += w.pairs.items.len;
    try pairs.ensureTotalCapacity(parenas[0].allocator(), total);
    for (workers) |w| try pairs.appendSlice(parenas[0].allocator(), w.pairs.items);

    // Build-phase transients (bus-group candidates) die here,
    // not in the retained pair arenas they would bloat.
    var build_tmp = std.heap.ArenaAllocator.init(parent);
    defer build_tmp.deinit();
    var en = workers[0].en;
    en.pair_alloc = build_tmp.allocator();

    var out: std.ArrayListUnmanaged(Crossing) = .empty;
    // Presized: millions of pairs double the list into gigabytes
    // of retained arena slack; enumeration holds one vector.
    try out.ensureTotalCapacity(alloc, pairs.items.len);
    // Emit already applied keepPair; every pair here builds.
    for (pairs.items) |pr| {
        try out.append(alloc, try en.buildCrossing(pr, null));
    }
    try en.appendBusGroups(&pairs, &out);
    // Sort indices, not records: a Crossing spans hundreds of
    // bytes, so swapping them moves gigabytes. IDs are unique,
    // so the gathered order matches the in-place sort exactly.
    const order = try alloc.alloc(u32, out.items.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, out.items, struct {
        fn less(xs: []Crossing, a: u32, b: u32) bool {
            return std.mem.lessThan(u8, xs[a].id, xs[b].id);
        }
    }.less);
    const sorted = try alloc.alloc(Crossing, out.items.len);
    for (order, 0..) |o, i| sorted[i] = out.items[o];
    return .{ .backing = backing, .parenas = parenas, .crossings = sorted };
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
    const ca = portBits(a, pin) orelse return false;
    const cb = portBits(b, pin) orelse return false;
    if (ca.len == 0 or ca.len != cb.len) return false;
    for (ca, cb) |x, y| {
        if (x != .sig or y != .sig or x.sig != y.sig) return false;
    }
    return true;
}

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
    }
    return null;
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

const Enumerator = struct {
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    alloc: std.mem.Allocator,
    pair_alloc: std.mem.Allocator,
    scratch: *std.heap.ArenaAllocator,
    clock_of: *const std.AutoHashMapUnmanaged(usize, clock.trace.Domain),
    bit_domains: *const std.AutoHashMapUnmanaged(u32, clock.trace.Domain),
    idx: *const walkidx.Index,
    visit: *walkidx.Visit,

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
                // Control arrivals emit, then keep walking: the value
                // still reaches the clock, so the glitch path survives.
                if (ld.control) {
                    try en.emit(pairs, src_cell, src_port, src_bit, src_lane, ld.cell, ld.pin, b, ld.lane, null, true);
                }
                if (ld.sink) |cls| {
                    // Same-cell pairs are self-feedback, never
                    // crossings: a flop's Q reaching its own D
                    // through comb is a counter, not a CDC.
                    if (src_cell != null and src_cell.? == ld.cell) continue;
                    try en.emit(pairs, src_cell, src_port, src_bit, src_lane, ld.cell, ld.pin, b, ld.lane, cls, false);
                } else if (idx.cells[ld.cell].seq_or_memclock) {
                    // Unclassified sequential inputs end the walk:
                    // boundaries cut, never go transparent.
                    continue;
                } else {
                    try en.propagate(ld.cell, ld, b, gen, &queue, tmp);
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
        ci: usize,
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
        if (en.knownPair(pr)) pr.hops = try en.reconstruct(b);
        try pairs.append(en.pair_alloc, pr);
    }

    // Both ends resolve to real clocks: the same predicate the
    // clock labels use, so a stored path always has two anchors.
    // The dispatcher additionally routes untyped-kind pairs past
    // per-pair rules; their paths serve the check_all owners.
    fn knownPair(en: *Enumerator, pr: Pair) bool {
        const dd = en.dstDomain(pr) orelse return false;
        if (std.mem.eql(u8, dd.name, "unknown")) return false;
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

    // Bus groups cut from key-sorted runs: pairs sharing (src
    // cell-or-port + pin, dst cell + pin) gain one bus record
    // beside their bit records. Ports group by port identity.
    fn appendBusGroups(
        en: *Enumerator,
        pairs: *const std.ArrayListUnmanaged(Pair),
        out: *std.ArrayListUnmanaged(Crossing),
    ) error{OutOfMemory}!void {
        var cand: std.ArrayListUnmanaged(usize) = .empty;
        for (pairs.items, 0..) |pr, i| {
            if (pr.src_cell) |sc| {
                if (en.mod.cells[sc].blackbox) continue;
            }
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
                const bkind: Kind = if (pairs.items[run[0]].src_cell == null) .port_flop_bus else .flop_flop_bus;
                var bus = try en.buildCrossing(pairs.items[run[0]], bkind);
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
        // Same clock net beats every doubt, including unknown: one
        // wire means one edge, whatever the tracer resolved. Opaque
        // sources stay out: unclocked data proves nothing by net.
        if (pr.src_cell) |sc| {
            if (!opaqueSource(en.mod.cells[sc]) and sameClockNet(en.mod, sc, pr.dst_cell)) return false;
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
// Integer twin of the retired string-keyed outLane: same
// lane-or-broadcast verdict from the resolved load and cell.
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
    return std.mem.eql(u8, a.src_port, b.src_port) and
        a.dst_cell == b.dst_cell and std.mem.eql(u8, a.dst_pin, b.dst_pin);
}

