const std = @import("std");
const bus = @import("bus.zig");
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
    if (ctx.model.clocks.count() < 2) return out.toOwnedSlice(ctx.alloc);
    if (ctx.table.combines.len == 0) return out.toOwnedSlice(ctx.alloc);
    const net_of = try netNames(ctx);
    for (ctx.table.combines) |cb| {
        const c = ctx.mod.cells[cb.cell];
        const net = net_of.get(cb.bit) orelse try std.fmt.allocPrint(ctx.alloc, "{s}.Y", .{c.name});
        const sinks = try combineSinks(ctx, cb.bit);
        std.mem.sort(usize, sinks, ctx, struct {
            fn less(cx: *context.Context, a: usize, b: usize) bool {
                return std.mem.order(u8, cx.mod.cells[a].name, cx.mod.cells[b].name) == .lt;
            }
        }.less);
        const clocks = try std.mem.join(ctx.alloc, ", ", cb.clocks);
        const sample = try sinkSample(ctx, sinks);
        const message = try std.fmt.allocPrint(ctx.alloc,
            "CLK net `{s}` driven by combine of {{{s}}} at `{s}` (`{s}`): two distinct declared clocks are mixed combinationally onto one clock net. The net glitches and runs at no declared frequency; the clock-root tracer declines to assign a domain through it, leaving the {d} flop(s) it reaches ({s}) domain-unknown and their crossings unchecked. Gate ONE clock and use the other only as a synchronised enable, or select between them with a glitchless clock mux (a mux selects and is not reported here).",
            .{ net, clocks, c.name, c.type, sinks.len, sample });
        try out.append(ctx.alloc, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = c.name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.alloc);
}

// First netname claiming each bit wins: elaborators name every
// net once, so collisions mean aliases of one net anyway.
fn netNames(ctx: *context.Context) error{OutOfMemory}!std.AutoHashMapUnmanaged(u32, []const u8) {
    var names = std.AutoHashMapUnmanaged(u32, []const u8).empty;
    var nit = ctx.mod.netnames.iterator();
    while (nit.next()) |ne| {
        for (ne.value_ptr.bits) |b| {
            if (b != .sig) continue;
            const slot = try names.getOrPut(ctx.alloc, b.sig);
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
    for (ctx.mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        const clk = bus.portBits(c, "CLK") orelse continue;
        for (clk) |b| {
            if (b != .sig) continue;
            if (try reaches(ctx, b.sig, bit)) {
                try sinks.append(ctx.alloc, ci);
                break;
            }
        }
    }
    return sinks.toOwnedSlice(ctx.alloc);
}

const Hop = struct { bit: u32, depth: u8 };

fn reaches(ctx: *context.Context, from: u32, target: u32) error{OutOfMemory}!bool {
    const mod = ctx.mod;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var queue = std.ArrayListUnmanaged(Hop).empty;
    try queue.append(ctx.alloc, .{ .bit = from, .depth = 0 });
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const h = queue.items[head];
        if (h.bit == target) return true;
        if (seen.contains(h.bit)) continue;
        try seen.put(ctx.alloc, h.bit, {});
        if (h.depth >= 16) continue;
        const drv = mod.driver_of.get(h.bit) orelse continue;
        const ci = drv.cell orelse continue;
        const c = mod.cells[ci];
        if (c.blackbox) continue;
        if (clock.cells.isSequential(c.type)) {
            const clk = bus.portBits(c, "CLK") orelse bus.portBits(c, "G") orelse bus.portBits(c, "EN") orelse continue;
            for (clk) |b| {
                if (b == .sig) try queue.append(ctx.alloc, .{ .bit = b.sig, .depth = h.depth + 1 });
            }
            continue;
        }
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b == .sig) try queue.append(ctx.alloc, .{ .bit = b.sig, .depth = h.depth + 1 });
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
        if (i > 0) try buf.appendSlice(ctx.alloc, ", ");
        const one = try std.fmt.allocPrint(ctx.alloc, "`{s}`", .{ctx.mod.cells[s].name});
        try buf.appendSlice(ctx.alloc, one);
    }
    if (sinks.len > show) {
        const tail = try std.fmt.allocPrint(ctx.alloc, ", +{d} more", .{sinks.len - show});
        try buf.appendSlice(ctx.alloc, tail);
    }
    return buf.toOwnedSlice(ctx.alloc);
}
