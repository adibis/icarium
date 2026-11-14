// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-017",
    .severity = .err,
    .title = "Transparent latch in a CDC path",
    .doc =
    \\A latch sits between a source flop and a destination flop in
    \\different clocks: while the enable holds, the foreign signal
    \\flows transparently to the destination with no resolution
    \\time. Replace the latch with a 2FF chain on the dst clock.
    ,
    .honors = &.{"cdc_sync"},
    .check_all = checkAll,
};

// Every latch, whole-design: the crossing walker stops at latch
// D pins, so without this rule the bug below is fully silent.
// One finding per (latch, src clock, dst clock) triple.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var seen = std.HashMapUnmanaged(Triple, void, TripleCtx, std.hash_map.default_max_load_percentage).empty;
    for (ctx.mod.cells, 0..) |c, ci| {
        if (!isCdcLatch(c.type)) continue;
        const q = c.portBits("Q") orelse continue;
        const d = c.portBits("D") orelse continue;
        if (q.len == 0 or d.len == 0) continue;
        const dsts = try dstByClock(ctx, q);
        if (dsts.count() == 0) continue;
        var dbits = std.ArrayListUnmanaged(ir.bits.Bit).empty;
        for (d) |b| {
            if (b == .sig) try dbits.append(ctx.tmp, b);
        }
        if (dbits.items.len == 0) continue;
        const srcs = try srcByClock(ctx, dbits.items);
        if (srcs.count() == 0) continue;
        var dit = dsts.iterator();
        while (dit.next()) |de| {
            var sit = srcs.iterator();
            while (sit.next()) |se| {
                if (std.mem.eql(u8, se.key_ptr.*, de.key_ptr.*)) continue;
                const key = Triple{ .latch = ci, .src = se.key_ptr.*, .dst = de.key_ptr.* };
                if (seen.contains(key)) continue;
                try seen.put(ctx.tmp, key, {});
                const message = try std.fmt.allocPrint(ctx.tmp, "transparent latch in CDC path {s} -> {s}: latch {s} feeds destination flop {s} (in {s}) from source flop {s} (in {s}). During the latch's enable-active phase the foreign-domain signal propagates transparently to the destination, with no metastability resolution. Replace the latch with a 2FF synchroniser flop chain on {s}.", .{ se.key_ptr.*, de.key_ptr.*, c.name, ctx.mod.cells[de.value_ptr.*].name, de.key_ptr.*, ctx.mod.cells[se.value_ptr.*].name, se.key_ptr.*, de.key_ptr.* });
                try out.append(ctx.tmp, .{
                    .rule = rule.id,
                    .severity = rule.severity,
                    .dst = c.name,
                    .message = message,
                });
            }
        }
    }
    return out.toOwnedSlice(ctx.tmp);
}

const Triple = struct { latch: usize, src: []const u8, dst: []const u8 };

// Slices hash by content: the default auto-hash refuses them,
// so the triple carries its own context. Eql, not the hash,
// decides identity; the separator only spreads buckets.
const TripleCtx = struct {
    pub fn hash(_: TripleCtx, k: Triple) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.latch));
        h.update(k.src);
        h.update("\x00");
        h.update(k.dst);
        return h.final();
    }
    pub fn eql(_: TripleCtx, a: Triple, b: Triple) bool {
        return a.latch == b.latch and
            std.mem.eql(u8, a.src, b.src) and
            std.mem.eql(u8, a.dst, b.dst);
    }
};

// The reference predicate exactly: $dlatch plus the gate-level
// family. Set/reset latches stay out, matching the reference.
fn isCdcLatch(cell_type: []const u8) bool {
    return std.mem.eql(u8, cell_type, "$dlatch") or
        std.mem.startsWith(u8, cell_type, "$_DLATCH_");
}

// First dst flop per clock reading the latch Q: vouched and
// unclocked destinations never seed a finding.
fn dstByClock(
    ctx: *context.Context,
    q: []ir.bits.Bit,
) error{OutOfMemory}!std.StringHashMapUnmanaged(usize) {
    var dsts = std.StringHashMapUnmanaged(usize).empty;
    for (q) |b| {
        if (b != .sig) continue;
        const dst = ctx.table.d_bit_to_flop.get(b.sig) orelse continue;
        if (clock.cells.isLatch(ctx.mod.cells[dst].type)) continue;
        if (ctx.marks.hasSync(ctx.mod.cells[dst].name)) continue;
        const dom = ctx.table.domainOf(dst) orelse continue;
        if (std.mem.eql(u8, dom.name, "unknown")) continue;
        const slot = try dsts.getOrPut(ctx.tmp, dom.name);
        if (!slot.found_existing) slot.value_ptr.* = dst;
    }
    return dsts;
}

// First src flop per clock behind the latch D, walking back
// through any intermediate comb. Clockless drivers abstain.
fn srcByClock(
    ctx: *context.Context,
    d: []ir.bits.Bit,
) error{OutOfMemory}!std.StringHashMapUnmanaged(usize) {
    var srcs = std.StringHashMapUnmanaged(usize).empty;
    const fanin = try context.backwardFlopFanin(ctx.tmp, ctx.mod, d);
    for (fanin.items) |f| {
        const dom = ctx.table.domainOf(f) orelse continue;
        if (std.mem.eql(u8, dom.name, "unknown")) continue;
        const slot = try srcs.getOrPut(ctx.tmp, dom.name);
        if (!slot.found_existing) slot.value_ptr.* = f;
    }
    return srcs;
}
