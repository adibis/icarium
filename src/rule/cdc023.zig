// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-023",
    .severity = .warn,
    .title = "Clock net driven by a combine of declared clocks",
    .doc =
    \\A gate mixes two or more declared clocks onto one net: the net
    \\glitches, runs at no declared frequency, and leaves its flops
    \\domainless. Gate one clock, or mux instead of mixing.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// The tracer's own declines, reported with net, clocks, and the
// flops each combine reaches. Fewer than two declared clocks
// means no combine is possible, so the rule stays out.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    if (ctx.model.clocks.count() < 2) return out.toOwnedSlice(ctx.tmp);
    if (ctx.table.combines.len == 0) return out.toOwnedSlice(ctx.tmp);
    const net_of = try netNames(ctx);
    for (ctx.table.combines) |cb| {
        const c = ctx.mod.cells[cb.cell];
        const net = net_of.get(cb.bit) orelse try std.fmt.allocPrint(ctx.tmp, "{s}.Y", .{c.name});
        const sinks = try combineSinks(ctx, cb.bit);
        std.mem.sort(usize, sinks, ctx, struct {
            fn less(cx: *context.Context, a: usize, b: usize) bool {
                return std.mem.order(u8, cx.mod.cells[a].name, cx.mod.cells[b].name) == .lt;
            }
        }.less);
        const clocks = try std.mem.join(ctx.tmp, ", ", cb.clocks);
        const sample = try sinkSample(ctx, sinks);
        const message = try std.fmt.allocPrint(ctx.tmp, "CLK net `{s}` driven by combine of {{{s}}} at `{s}` (`{s}`): two distinct declared clocks are mixed combinationally onto one clock net. The net glitches and runs at no declared frequency; the clock-root tracer declines to assign a domain through it, leaving the {d} flop(s) it reaches ({s}) domain-unknown and their crossings unchecked. Gate ONE clock and use the other only as a synchronised enable, or select between them with a glitchless clock mux (a mux selects and is not reported here).", .{ net, clocks, c.name, c.type, sinks.len, sample });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = c.name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

// First netname claiming each bit wins: elaborators name every
// net once, so collisions mean aliases of one net anyway.
fn netNames(ctx: *context.Context) error{OutOfMemory}!std.AutoHashMapUnmanaged(u32, []const u8) {
    var names = std.AutoHashMapUnmanaged(u32, []const u8).empty;
    var nit = ctx.mod.netnames.iterator();
    while (nit.next()) |ne| {
        for (ne.value_ptr.bits) |b| {
            if (b != .sig) continue;
            const slot = try names.getOrPut(ctx.tmp, b.sig);
            if (!slot.found_existing) slot.value_ptr.* = ne.key_ptr.*;
        }
    }
    return names;
}

// Flops whose clock cone contains the combine bit: an upstream
// walk from every CLK, mirroring the tracer's own transit
// (transparent, mux, gate, divider master) within 16 hops.
fn combineSinks(ctx: *context.Context, bit: u32) error{OutOfMemory}![]usize {
    var sinks = std.ArrayListUnmanaged(usize).empty;
    // Walks die per flop: clock cones span the design, and one
    // retained walk per flop exhausts memory at full-chip scale.
    var backing = ctx.table.workArena();
    defer backing.deinit();
    var scratch = std.heap.ArenaAllocator.init(backing.allocator());
    defer scratch.deinit();
    for (ctx.mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        const clk = c.portBits("CLK") orelse continue;
        for (clk) |b| {
            if (b != .sig) continue;
            _ = scratch.reset(.retain_capacity);
            if (try reaches(ctx, scratch.allocator(), b.sig, bit)) {
                try sinks.append(ctx.tmp, ci);
                break;
            }
        }
    }
    return sinks.toOwnedSlice(ctx.tmp);
}

const Hop = struct { bit: u32, depth: u8 };

fn reaches(ctx: *context.Context, alloc: std.mem.Allocator, from: u32, target: u32) error{OutOfMemory}!bool {
    const mod = ctx.mod;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var queue = std.ArrayListUnmanaged(Hop).empty;
    try queue.append(alloc, .{ .bit = from, .depth = 0 });
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const h = queue.items[head];
        if (h.bit == target) return true;
        if (seen.contains(h.bit)) continue;
        try seen.put(alloc, h.bit, {});
        if (h.depth >= 16) continue;
        const drv = mod.driver_of.get(h.bit) orelse continue;
        const ci = drv.cell orelse continue;
        const c = mod.cells[ci];
        if (c.blackbox) continue;
        if (clock.cells.isSequential(c.type)) {
            const clk = c.portBits("CLK") orelse c.portBits("G") orelse c.portBits("EN") orelse continue;
            for (clk) |b| {
                if (b == .sig) try queue.append(alloc, .{ .bit = b.sig, .depth = h.depth + 1 });
            }
            continue;
        }
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b == .sig) try queue.append(alloc, .{ .bit = b.sig, .depth = h.depth + 1 });
            }
        }
    }
    return false;
}

// Three sink names, then a remainder: combines fan wide, and
// the count already says how wide.
fn sinkSample(ctx: *context.Context, sinks: []usize) error{OutOfMemory}![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    const show = @min(sinks.len, 3);
    for (sinks[0..show], 0..) |s, i| {
        if (i > 0) try buf.appendSlice(ctx.tmp, ", ");
        const one = try std.fmt.allocPrint(ctx.tmp, "`{s}`", .{ctx.mod.cells[s].name});
        try buf.appendSlice(ctx.tmp, one);
    }
    if (sinks.len > show) {
        const tail = try std.fmt.allocPrint(ctx.tmp, ", +{d} more", .{sinks.len - show});
        try buf.appendSlice(ctx.tmp, tail);
    }
    return buf.toOwnedSlice(ctx.tmp);
}
