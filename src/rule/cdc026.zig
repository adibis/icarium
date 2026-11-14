// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-026",
    .severity = .note,
    .title = "Multiclock crossing leg-pair report",
    .doc =
    \\A crossing whose source or receiver runs on a muxed clock:
    \\each side may arrive on several legs, and one leg pair can be
    \\safe while another is not. One finding per endpoint lists the
    \\clock sets, the mux selections behind them, every leg pair with
    \\its relationship, and the destination chain depth. Multiple
    \\clocks alone prove nothing; review the pairs, then waive or fix.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// Union-involved crossings gather by destination; each endpoint
// fires once with its sets, pairs, and selects. Sync marks never
// silence the ledger: a handled multiclock path is exactly the
// shape waivers record, so the record fires either way.
pub const Accum = struct {
    groups: std.AutoHashMapUnmanaged(usize, std.StringHashMapUnmanaged(Group)) = .empty,
};

pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var acc = Accum{};
    for (ctx.crossings) |x| try accumulate(&acc, ctx, x);
    return finish(&acc, ctx);
}

pub fn accumulate(acc: *Accum, ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!void {
    switch (x.kind) {
        .flop_flop_bit, .flop_flop_bus, .port_flop, .port_flop_untyped, .port_flop_bus => {},
        else => return,
    }
    const dc = x.dst.cell orelse return;
    const dst = sideOf(ctx, .{ .cell = dc });
    const src = if (x.src.cell) |sc|
        sideOf(ctx, .{ .cell = sc })
    else
        Side{ .legs = &.{x.src_clk}, .sels = &.{}, .muxes = &.{} };
    if (src.legs.len < 2 and dst.legs.len < 2) return;
    // Nested by destination, then source clock: formatting a key
    // per crossing allocs for every probe, not just inserts.
    const outer = try acc.groups.getOrPut(ctx.alloc, dc);
    if (!outer.found_existing) outer.value_ptr.* = .empty;
    const g = try outer.value_ptr.getOrPut(ctx.alloc, x.src_clk);
    if (!g.found_existing) {
        g.key_ptr.* = try ctx.alloc.dupe(u8, x.src_clk);
        g.value_ptr.* = .{
            .dst = dc,
            .dst_clk = try ctx.alloc.dupe(u8, x.dst_clk),
            .dst_legs = dst.legs,
            .dst_sels = dst.sels,
            .dst_muxes = dst.muxes,
        };
    }
    const gr = g.value_ptr;
    gr.count += 1;
    for (src.legs) |sl| try pushDistinct(ctx.alloc, &gr.src_legs, sl);
    for (src.muxes) |m| try pushDistinctUsize(ctx.alloc, &gr.src_muxes, m);
    const sname = if (x.src.cell) |sc| ctx.mod.cells[sc].name else x.src.port;
    try gr.addSample(ctx.alloc, sname);
    for (src.legs, 0..) |sl, i| {
        const ssel: ?clock.trace.LegSel = if (i < src.sels.len) src.sels[i] else null;
        for (dst.legs, 0..) |dl, j| {
            const dsel: ?clock.trace.LegSel = if (j < dst.sels.len) dst.sels[j] else null;
            try pushPair(ctx, gr, sl, dl, ssel, dsel);
        }
    }
}

pub fn finish(acc: *Accum, ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var scratch = std.heap.ArenaAllocator.init(ctx.alloc);
    defer scratch.deinit();
    var keys = std.ArrayListUnmanaged(Key).empty;
    var oit = acc.groups.iterator();
    while (oit.next()) |oe| {
        var iit = oe.value_ptr.iterator();
        while (iit.next()) |ie| {
            ie.value_ptr.sortAll(ctx);
            // Print order keys on the joined string, formatted
            // once per group: per-crossing formats would dominate.
            const joined = try std.fmt.allocPrint(ctx.tmp, "{s}|{s}", .{ ctx.mod.cells[oe.key_ptr.*].name, ie.key_ptr.* });
            try keys.append(ctx.tmp, .{ .order = joined, .group = ie.value_ptr });
        }
    }
    std.mem.sort(Key, keys.items, {}, struct {
        fn less(_: void, a: Key, b: Key) bool {
            return std.mem.lessThan(u8, a.order, b.order);
        }
    }.less);
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    for (keys.items) |k| {
        _ = scratch.reset(.retain_capacity);
        try out.append(ctx.tmp, try fire(ctx, scratch.allocator(), k.group.*));
    }
    return out.toOwnedSlice(ctx.tmp);
}

const Key = struct {
    order: []const u8,
    group: *Group,
};

const Side = struct {
    legs: []const []const u8,
    sels: []const clock.trace.LegSel,
    muxes: []const usize,
};

const unknown_legs: []const []const u8 = &.{"unknown"};

fn sideOf(ctx: *context.Context, ep: struct { cell: usize }) Side {
    const dom = ctx.table.domainOf(ep.cell) orelse return .{ .legs = unknown_legs, .sels = &.{}, .muxes = &.{} };
    return .{ .legs = dom.legs, .sels = dom.sels, .muxes = dom.muxes };
}

const Group = struct {
    dst: usize,
    dst_clk: []const u8,
    dst_legs: []const []const u8,
    dst_sels: []const clock.trace.LegSel,
    dst_muxes: []const usize,
    src_legs: std.ArrayListUnmanaged([]const u8) = .empty,
    src_muxes: std.ArrayListUnmanaged(usize) = .empty,
    pairs: std.ArrayListUnmanaged(Pair) = .empty,
    samples: [4][]const u8 = undefined,
    nsamples: usize = 0,
    count: usize = 0,

    // Smallest four source names: repeat crossings from one
    // flop share a bit, not a story, and minima print the
    // same witnesses whatever order the batches arrive in.
    // Samples copy out on insert: batch crossings die young.
    fn addSample(self: *Group, alloc: std.mem.Allocator, sname: []const u8) error{OutOfMemory}!void {
        var pos: usize = 0;
        while (pos < self.nsamples) : (pos += 1) {
            const ord = std.mem.order(u8, sname, self.samples[pos]);
            if (ord == .eq) return;
            if (ord == .lt) break;
        }
        if (pos >= self.samples.len) return;
        const owned = try alloc.dupe(u8, sname);
        var j = @min(self.nsamples, self.samples.len - 1);
        while (j > pos) : (j -= 1) self.samples[j] = self.samples[j - 1];
        self.samples[pos] = owned;
        if (self.nsamples < self.samples.len) self.nsamples += 1;
    }

    // Canonical print order: legs, muxes, and pairs gather in
    // arrival order, which differs between the whole-report
    // run and streamed batches. Sorted, both print alike.
    fn sortAll(self: *Group, ctx: *context.Context) void {
        std.mem.sort([]const u8, self.src_legs.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        std.mem.sort(usize, self.src_muxes.items, ctx, struct {
            fn less(c: *context.Context, a: usize, b: usize) bool {
                return std.mem.order(u8, c.mod.cells[a].name, c.mod.cells[b].name) == .lt;
            }
        }.less);
        std.mem.sort(Pair, self.pairs.items, {}, struct {
            fn less(_: void, a: Pair, b: Pair) bool {
                const s = std.mem.order(u8, a.sl, b.sl);
                if (s != .eq) return s == .lt;
                return std.mem.order(u8, a.dl, b.dl) == .lt;
            }
        }.less);
    }
};

const Pair = struct { sl: []const u8, dl: []const u8, rel: Rel };
const Rel = enum { async, sync, unknown, exclusive };

fn pushDistinct(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), v: []const u8) error{OutOfMemory}!void {
    for (list.items) |e| {
        if (std.mem.eql(u8, e, v)) return;
    }
    // Legs copy out on insert: port legs borrow the crossing,
    // and the accumulator outlives the batch.
    try list.append(alloc, try alloc.dupe(u8, v));
}

fn pushDistinctUsize(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(usize), v: usize) error{OutOfMemory}!void {
    for (list.items) |e| {
        if (e == v) return;
    }
    try list.append(alloc, v);
}

// A pair's relationship: exclusivity first (shared select bit,
// opposite $mux sides, never co-active), then unknown, then the
// SDC verdict. OR-mux legs always co-occur here: their enables
// are independent signals, whatever the handshake guarantees.
fn relate(ctx: *context.Context, sl: []const u8, dl: []const u8, ssel: ?clock.trace.LegSel, dsel: ?clock.trace.LegSel) Rel {
    if (exclusive(ctx, ssel, dsel)) return .exclusive;
    if (std.mem.eql(u8, sl, "unknown") or std.mem.eql(u8, dl, "unknown")) return .unknown;
    if (ctx.model.declaredAsync(sl, dl)) return .async;
    return .sync;
}

// Same select net, opposite $mux sides: one bit cannot take
// both values, so the pair never occurs. Raw net identity only;
// buf-split selects stay co-occurrent (conservative miss).
fn exclusive(ctx: *context.Context, ssel: ?clock.trace.LegSel, dsel: ?clock.trace.LegSel) bool {
    const a = ssel orelse return false;
    const b = dsel orelse return false;
    if (a.side == b.side) return false;
    if (a.side == clock.trace.both_sides or b.side == clock.trace.both_sides) return false;
    if (!clock.cells.isClockMux(ctx.mod.cells[a.mux].type)) return false;
    if (!clock.cells.isClockMux(ctx.mod.cells[b.mux].type)) return false;
    const sa = selBit(ctx.mod.cells[a.mux]) orelse return false;
    const sb = selBit(ctx.mod.cells[b.mux]) orelse return false;
    return sa == sb;
}

fn selBit(c: ir.types.Cell) ?u32 {
    const s = c.portBits("S") orelse return null;
    if (s.len == 0 or s[0] != .sig) return null;
    return s[0].sig;
}

fn pushPair(
    ctx: *context.Context,
    gr: *Group,
    sl: []const u8,
    dl: []const u8,
    ssel: ?clock.trace.LegSel,
    dsel: ?clock.trace.LegSel,
) error{OutOfMemory}!void {
    const rel = relate(ctx, sl, dl, ssel, dsel);
    for (gr.pairs.items) |*p| {
        if (!std.mem.eql(u8, p.sl, sl) or !std.mem.eql(u8, p.dl, dl)) continue;
        // Same legs down another path: exclusivity needs every
        // path exclusive, so a plain verdict wins the merge.
        if (p.rel == .exclusive and rel != .exclusive) p.rel = rel;
        return;
    }
    try gr.pairs.append(ctx.alloc, .{
        .sl = try ctx.alloc.dupe(u8, sl),
        .dl = try ctx.alloc.dupe(u8, dl),
        .rel = rel,
    });
}

fn relWord(r: Rel) []const u8 {
    return switch (r) {
        .async => "async",
        .sync => "sync",
        .unknown => "unknown",
        .exclusive => "exclusive",
    };
}

// One driver reference: the signal a selection or enable rides
// on. Flop drivers name their domain (mode-switch timing);
// anything else names the net and leaves timing unresolved.
fn driveRef(ctx: *context.Context, alloc: std.mem.Allocator, bit: u32) error{OutOfMemory}![]const u8 {
    const drv = ctx.mod.driver_of.get(bit) orelse return try alloc.dupe(u8, "undriven");
    const ci = drv.cell orelse return try std.fmt.allocPrint(alloc, "port {s}", .{drv.port});
    const c = ctx.mod.cells[ci];
    if (clock.cells.isSequential(c.type) and std.mem.eql(u8, drv.port, "Q")) {
        const dom = ctx.table.domainOf(ci) orelse return try std.fmt.allocPrint(alloc, "flop {s}", .{c.name});
        return try std.fmt.allocPrint(alloc, "flop {s} ({s})", .{ c.name, dom.name });
    }
    return try std.fmt.allocPrint(alloc, "comb {s}", .{c.name});
}

// $mux side conditions: which legs each select value takes, and
// what drives the select. Sides are definitional ($mux picks A
// on 0, B on 1), so no value analysis is needed to state them.
fn muxConds(
    ctx: *context.Context,
    alloc: std.mem.Allocator,
    mux: usize,
    legs: []const []const u8,
    sels: []const clock.trace.LegSel,
) error{OutOfMemory}![]const u8 {
    const c = ctx.mod.cells[mux];
    var a = std.ArrayListUnmanaged([]const u8).empty;
    var b = std.ArrayListUnmanaged([]const u8).empty;
    var either = std.ArrayListUnmanaged([]const u8).empty;
    for (legs, 0..) |l, i| {
        const s: ?clock.trace.LegSel = if (i < sels.len) sels[i] else null;
        if (s == null or s.?.mux != mux or s.?.side == clock.trace.both_sides) {
            try either.append(alloc, l);
        } else if (s.?.side == 0) {
            try a.append(alloc, l);
        } else {
            try b.append(alloc, l);
        }
    }
    const s = c.portBits("S") orelse return try alloc.dupe(u8, "malformed mux");
    const ref = if (s.len > 0 and s[0] == .sig) try driveRef(ctx, alloc, s[0].sig) else try alloc.dupe(u8, "constant");
    const ja = try joinLegs(alloc, a.items);
    const jb = try joinLegs(alloc, b.items);
    const je = try joinLegs(alloc, either.items);
    const either_part = if (either.items.len == 0)
        try alloc.dupe(u8, "")
    else
        try std.fmt.allocPrint(alloc, "; either side takes {{{s}}}", .{je});
    return try std.fmt.allocPrint(alloc, "$mux {s}: S=0 takes {{{s}}}, S=1 takes {{{s}}}{s} (S driven by {s})", .{
        c.name, ja, jb, either_part, ref,
    });
}

// OR-mux leg conditions: each leg's AND with its enables (every
// non-clock input). Legs are independently enabled, so pairs
// co-occur here; the handshake's mutual exclusion is protocol,
// not structure, and stays unverified.
fn orConds(
    ctx: *context.Context,
    alloc: std.mem.Allocator,
    mux: usize,
    legs: []const []const u8,
    sels: []const clock.trace.LegSel,
) error{OutOfMemory}![]const u8 {
    const c = ctx.mod.cells[mux];
    var parts = std.ArrayListUnmanaged([]const u8).empty;
    var multi_and = false;
    for (legs, 0..) |l, i| {
        const s: ?clock.trace.LegSel = if (i < sels.len) sels[i] else null;
        if (s == null or s.?.mux != mux) continue;
        const g = s.?.gate orelse continue;
        if (s.?.side == clock.trace.both_sides) multi_and = true;
        const gc = ctx.mod.cells[g.cell];
        var ens = std.ArrayListUnmanaged([]const u8).empty;
        for (gc.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |bit| {
                if (bit != .sig or bit.sig == g.bit) continue;
                if (ens.items.len < 4) try ens.append(alloc, try driveRef(ctx, alloc, bit.sig));
            }
        }
        const je = try joinLegs(alloc, ens.items);
        try parts.append(alloc, try std.fmt.allocPrint(alloc, "{s} via {s} gated by {s}{s}", .{
            l,                                   gc.name, if (je.len == 0) "nothing" else je,
            if (ens.items.len == 4) "+" else "",
        }));
    }
    const jp = try joinLegs(alloc, parts.items);
    return try std.fmt.allocPrint(alloc, "or-mux {s}: legs independently enabled ({s}){s}", .{
        c.name,                                                               jp,
        if (multi_and) " [leg under several ANDs: first gate shown]" else "",
    });
}

fn joinLegs(alloc: std.mem.Allocator, legs: []const []const u8) error{OutOfMemory}![]const u8 {
    if (legs.len == 0) return try alloc.dupe(u8, "");
    var total: usize = 0;
    for (legs) |l| total += l.len + 2;
    const out = try alloc.alloc(u8, total - 2);
    var off: usize = 0;
    for (legs, 0..) |l, i| {
        if (i > 0) {
            out[off] = ',';
            out[off + 1] = ' ';
            off += 2;
        }
        @memcpy(out[off..][0..l.len], l);
        off += l.len;
    }
    return out;
}

fn fire(ctx: *context.Context, alloc: std.mem.Allocator, gr: Group) error{OutOfMemory}!finding.Finding {
    const dst_name = ctx.mod.cells[gr.dst].name;
    const depth = try ctx.table.chainDepth(ctx.mod, gr.dst, gr.dst_clk);
    var conds = std.ArrayListUnmanaged([]const u8).empty;
    if (gr.dst_muxes.len > 0) {
        const top = gr.dst_muxes[0];
        if (clock.cells.isClockMux(ctx.mod.cells[top].type)) {
            try conds.append(alloc, try muxConds(ctx, alloc, top, gr.dst_legs, gr.dst_sels));
        } else {
            try conds.append(alloc, try orConds(ctx, alloc, top, gr.dst_legs, gr.dst_sels));
        }
        if (gr.dst_muxes.len > 1) {
            var names = std.ArrayListUnmanaged([]const u8).empty;
            for (gr.dst_muxes[1..]) |m| try names.append(alloc, ctx.mod.cells[m].name);
            const jn = try joinLegs(alloc, names.items);
            try conds.append(alloc, try std.fmt.allocPrint(alloc, "also through {s} (nested conditions unrecorded)", .{jn}));
        }
    }
    var smux = std.ArrayListUnmanaged([]const u8).empty;
    for (gr.src_muxes.items) |m| {
        const kind: []const u8 = if (clock.cells.isClockMux(ctx.mod.cells[m].type)) "mux" else "or-mux";
        try smux.append(alloc, try std.fmt.allocPrint(alloc, "{s} {s}", .{ kind, ctx.mod.cells[m].name }));
    }
    var prs = std.ArrayListUnmanaged([]const u8).empty;
    for (gr.pairs.items) |p| {
        try prs.append(alloc, try std.fmt.allocPrint(alloc, "{s}x{s} {s}", .{ p.sl, p.dl, relWord(p.rel) }));
    }
    const jdl = try joinLegs(alloc, gr.dst_legs);
    const jsl = try joinLegs(alloc, gr.src_legs.items);
    const jco = try joinLegs(alloc, conds.items);
    const jsm = try joinLegs(alloc, smux.items);
    const jpr = try joinLegs(alloc, prs.items);
    const jsa = try joinLegs(alloc, gr.samples[0..gr.nsamples]);
    // Source-side unions leave the receiver unmuxed; the via
    // clause then reads empty, so it drops out entirely.
    const via = if (conds.items.len == 0) "" else try std.fmt.allocPrint(alloc, " via {s}", .{jco});
    const message = try std.fmt.allocPrint(ctx.tmp, "multiclock crossing on '{s}': receiver {{{s}}}{s}; {d} source crossings in {{{s}}} (sample: {s}{s}); {d} leg-pairs: {s}; chain depth {d}{s}{s}", .{
        dst_name,                                      jdl,                                                       via,
        gr.count,                                      jsl,                                                       jsa,
        if (gr.count > gr.nsamples) ", +more" else "", gr.pairs.items.len,                                        jpr,
        depth.depth,                                   if (gr.src_muxes.items.len == 0) "" else "; sources via ", jsm,
    });
    return .{
        .rule = rule.id,
        .severity = .note,
        .dst = dst_name,
        .message = message,
    };
}
