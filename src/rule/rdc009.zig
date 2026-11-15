// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");
const reset = @import("../reset.zig");

pub const rule = registry.Rule{
    .id = "RDC-009",
    .severity = .err,
    .title = "Unqualified data crossing reset domains",
    .doc =
    \\A flop's data input is driven from another reset domain with
    \\no shared release: the source can come out of reset while the
    \\receiver samples. Both sides need an async reset to trip it.
    \\This is a release check only: unreset storage fed from a reset
    \\domain stays silent here, though an async assertion at the
    \\source can still corrupt what it captures, a hazard icarium
    \\does not analyze. Clocks do not matter here.
    ,

    .honors = &.{},
    .check_all = checkAll,
};

// Cell-based, not crossing-based: same-clock pairs never reach
// enumeration, and reset-domain hazards ignore clocks entirely.
// One backward walk per D cone runs in a per-flop scratch arena;
// only findings survive into the caller arena. Each cone bit
// is visited at most twice (select-only, then data-upgraded).
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var scratch = std.heap.ArenaAllocator.init(ctx.alloc);
    defer scratch.deinit();
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    for (ctx.mod.cells, 0..) |c, dc| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        const d = c.portBits("D") orelse continue;
        _ = scratch.reset(.retain_capacity);
        const srcs = try dataFanin(ctx, scratch.allocator(), d);
        if (srcs.len == 0) continue;
        const dst_dom = try domainOf(ctx, scratch.allocator(), dc);
        var unknowns: usize = 0;
        for (srcs) |sc| {
            if (sc == dc) continue;
            const src_dom = try domainOf(ctx, scratch.allocator(), sc);
            if (src_dom.unknown or dst_dom.unknown) {
                unknowns += 1;
                continue;
            }
            if (sameDomain(dst_dom, src_dom)) continue;
            // Ordered release: every destination synchronizer derives
            // from the source's own roots, so the destination wakes
            // strictly after the source data settles. The textbook
            // safe order, recognized rather than flagged.
            if (try orderedRelease(ctx, scratch.allocator(), src_dom, dst_dom)) continue;
            try out.append(ctx.tmp, try fire(ctx, sc, dc, src_dom, dst_dom));
        }
        // Uncomparable sources aggregate per destination: one caveat,
        // never silence and never one row per unknown pair.
        if (unknowns > 0) {
            const message = try std.fmt.allocPrint(ctx.tmp, "reset domain comparison incomplete at {s}: {d} source{s} with unresolved reset origins cannot prove same-domain release; resolve the reset drivers or waive after review", .{ c.name, unknowns, if (unknowns == 1) "" else "s" });
            try out.append(ctx.tmp, .{
                .rule = rule.id,
                .severity = .warn,
                .dst = c.name,
                .message = message,
            });
        }
    }
    return out.toOwnedSlice(ctx.tmp);
}

// Nearest Q-drivers reachable without ending on a mux select:
// select-only arrivals are control (RDC-003's jurisdiction), and
// a synced select into a reset mux must not trip a data rule.
// Bits upgrade from select-only to data on revisit, so shared
// cones never double-count and never miss the data leg.
fn dataFanin(
    ctx: *context.Context,
    alloc: std.mem.Allocator,
    start: []ir.bits.Bit,
) error{OutOfMemory}![]usize {
    var data = std.AutoHashMapUnmanaged(u32, void).empty;
    var sel_seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(FaninBit).empty;
    for (start) |b| {
        if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = 0, .via_select = false });
    }
    var flops = std.AutoHashMapUnmanaged(usize, void).empty;
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const fb = frontier.items[head];
        if (fb.via_select) {
            if (data.contains(fb.bit) or sel_seen.contains(fb.bit)) continue;
            try sel_seen.put(alloc, fb.bit, {});
        } else {
            if (data.contains(fb.bit)) continue;
            try data.put(alloc, fb.bit, {});
        }
        const drv = ctx.mod.driver_of.get(fb.bit) orelse continue;
        const ci = drv.cell orelse continue;
        if (std.mem.eql(u8, drv.port, "Q")) {
            if (!fb.via_select) try flops.put(alloc, ci, {});
            continue;
        }
        if (fb.depth >= 12) continue;
        const c = ctx.mod.cells[ci];
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            const sel = fb.via_select or isMuxSelect(c, p.name);
            for (p.bits) |b| {
                if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = fb.depth + 1, .via_select = sel });
            }
        }
    }
    var out = std.ArrayListUnmanaged(usize).empty;
    var it = flops.iterator();
    while (it.next()) |e| try out.append(alloc, e.key_ptr.*);
    std.mem.sort(usize, out.items, {}, std.sort.asc(usize));
    return out.toOwnedSlice(alloc);
}

const FaninBit = struct { bit: u32, depth: u8, via_select: bool };

const Domain = struct {
    tags: []const []const u8,
    syncs: []const usize,
    unknown: bool,
};

// Ultimate reset roots per flop: gating and muxing between the pin
// and the release source do not fork a domain by themselves (the
// gates are RDC-004/005/006's verdict, not this rule's), so the
// walk passes through combinational legs to ports and flops. A
// flop stops it: a synchronizer output is a new release event.
// Tied-off constants never release and read as no domain.
fn domainOf(
    ctx: *context.Context,
    alloc: std.mem.Allocator,
    ci: usize,
) error{OutOfMemory}!Domain {
    const c = ctx.mod.cells[ci];
    const ap = reset.cells.canonicalAsyncPin(c) orelse return .{ .tags = &.{}, .syncs = &.{}, .unknown = false };
    const bits = c.portBits(ap.pin) orelse return .{ .tags = &.{}, .syncs = &.{}, .unknown = false };
    var tags = std.ArrayListUnmanaged([]const u8).empty;
    var syncs = std.ArrayListUnmanaged(usize).empty;
    var unknown = false;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(struct { bit: u32, depth: u8 }).empty;
    for (bits) |b| {
        if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = 0 });
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const fb = frontier.items[head];
        if (seen.contains(fb.bit)) continue;
        try seen.put(alloc, fb.bit, {});
        const drv = ctx.mod.driver_of.get(fb.bit) orelse {
            unknown = true;
            continue;
        };
        const dci = drv.cell orelse {
            try addTag(alloc, &tags, "port", drv.port);
            continue;
        };
        const dc = ctx.mod.cells[dci];
        if (clock.cells.isSequential(dc.type)) {
            try addTag(alloc, &tags, "flop", dc.name);
            var have = false;
            for (syncs.items) |s| {
                if (s == dci) have = true;
            }
            if (!have) try syncs.append(alloc, dci);
            continue;
        }
        if (dc.blackbox) {
            unknown = true;
            continue;
        }
        if (fb.depth >= 32) {
            unknown = true;
            continue;
        }
        for (dc.ports) |p| {
            if (p.direction == .output) continue;
            if (isMuxSelect(dc, p.name)) continue;
            for (p.bits) |b| {
                if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = fb.depth + 1 });
            }
        }
    }
    std.mem.sort([]const u8, tags.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return .{ .tags = tags.items, .syncs = syncs.items, .unknown = unknown };
}

// Every destination synchronizer transitively derives from ports
// the source's own release also derives from: the destination
// wakes strictly after the source data settles, which is the
// textbook safe order through derived reset trees and daisy
// chains alike. Unprovable legs refuse the silence.
fn orderedRelease(
    ctx: *context.Context,
    alloc: std.mem.Allocator,
    src_dom: Domain,
    dst_dom: Domain,
) error{OutOfMemory}!bool {
    if (dst_dom.syncs.len == 0) return false;
    const src_ports = try transitivePortsOfDomain(ctx, alloc, src_dom);
    if (src_ports.unknown) return false;
    for (dst_dom.syncs) |s| {
        const tp = try transitivePorts(ctx, alloc, s);
        if (tp.unknown or tp.ports.len == 0) return false;
        for (tp.ports) |t| {
            if (!hasPort(src_ports.ports, t)) return false;
        }
    }
    return true;
}

const PortSet = struct {
    ports: []const []const u8,
    unknown: bool,
};

fn transitivePortsOfDomain(
    ctx: *context.Context,
    alloc: std.mem.Allocator,
    dom: Domain,
) error{OutOfMemory}!PortSet {
    var ports = std.ArrayListUnmanaged([]const u8).empty;
    var unknown = false;
    for (dom.tags) |t| {
        if (std.mem.startsWith(u8, t, "port:")) try ports.append(alloc, t);
    }
    for (dom.syncs) |s| {
        const tp = try transitivePorts(ctx, alloc, s);
        if (tp.unknown) unknown = true;
        for (tp.ports) |t| {
            if (!hasPort(ports.items, t)) try ports.append(alloc, t);
        }
    }
    return .{ .ports = ports.items, .unknown = unknown };
}

fn hasPort(ports: []const []const u8, t: []const u8) bool {
    for (ports) |u| {
        if (std.mem.eql(u8, u, t)) return true;
    }
    return false;
}

// Ultimate port roots behind a reset synchronizer: through flop
// stages, which are chain links rather than new domains for this
// ordering question, and combinational legs to ports. Internal
// taps that share the root stay silent here; the RST_SYNC family
// names the tap shape with its own dedicated check.
fn transitivePorts(
    ctx: *context.Context,
    alloc: std.mem.Allocator,
    start: usize,
) error{OutOfMemory}!PortSet {
    // Release timing comes from the sync's own async pin: head
    // stages tie D to the inactive value, so D has no roots.
    const start_bits = resetBits(ctx.mod.cells[start]) orelse dataBits(ctx.mod.cells[start]) orelse return .{ .ports = &.{}, .unknown = true };
    const d = start_bits;
    var ports = std.ArrayListUnmanaged([]const u8).empty;
    var unknown = false;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var seen_flop = std.AutoHashMapUnmanaged(usize, void).empty;
    var frontier = std.ArrayListUnmanaged(struct { bit: u32, depth: u8 }).empty;
    for (d) |b| {
        if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = 0 });
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const fb = frontier.items[head];
        if (seen.contains(fb.bit)) continue;
        try seen.put(alloc, fb.bit, {});
        const drv = ctx.mod.driver_of.get(fb.bit) orelse {
            unknown = true;
            continue;
        };
        const dci = drv.cell orelse {
            const tag = try std.fmt.allocPrint(alloc, "port:{s}", .{drv.port});
            if (!hasPort(ports.items, tag)) try ports.append(alloc, tag);
            continue;
        };
        const dc = ctx.mod.cells[dci];
        if (clock.cells.isSequential(dc.type)) {
            if (seen_flop.contains(dci)) continue;
            try seen_flop.put(alloc, dci, {});
            const dd = resetBits(dc) orelse dataBits(dc) orelse {
                unknown = true;
                continue;
            };
            for (dd) |b| {
                if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = fb.depth + 1 });
            }
            continue;
        }
        if (dc.blackbox or fb.depth >= 64) {
            unknown = true;
            continue;
        }
        for (dc.ports) |p| {
            if (p.direction == .output) continue;
            if (isMuxSelect(dc, p.name)) continue;
            for (p.bits) |b| {
                if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = fb.depth + 1 });
            }
        }
    }
    return .{ .ports = ports.items, .unknown = unknown };
}

// Async-pin bits carrying a live signal; a tied-off constant
// pin reads as absent so the caller falls through to D.
fn resetBits(c: ir.types.Cell) ?[]ir.bits.Bit {
    const ap = reset.cells.canonicalAsyncPin(c) orelse return null;
    const bits = c.portBits(ap.pin) orelse return null;
    for (bits) |b| {
        if (b == .sig) return bits;
    }
    return null;
}

fn dataBits(c: ir.types.Cell) ?[]ir.bits.Bit {
    return c.portBits("D");
}

fn addTag(alloc: std.mem.Allocator, tags: *std.ArrayListUnmanaged([]const u8), kind: []const u8, ref: []const u8) error{OutOfMemory}!void {
    for (tags.items) |t| {
        if (t.len == kind.len + 1 + ref.len and std.mem.startsWith(u8, t, kind) and std.mem.eql(u8, t[kind.len + 1 ..], ref)) return;
    }
    try tags.append(alloc, try std.fmt.allocPrint(alloc, "{s}:{s}", .{ kind, ref }));
}

fn isMuxSelect(c: ir.types.Cell, pin: []const u8) bool {
    if (!std.mem.eql(u8, pin, "S")) return false;
    return std.mem.eql(u8, c.type, "$mux") or std.mem.eql(u8, c.type, "$pmux");
}

// Root sets compare by subset in either direction: gating a reset
// with enables does not fork its domain (the gates themselves are
// RDC-004/005/006's verdict), and an empty set sits inside every
// domain, which is the single-release silence for unreset logic.
// Only disjoint roots — different ports, different synchronizer
// taps — prove a crossing. Muxed supersets stay silent here;
// the mux finding carries the ambiguity instead.
fn sameDomain(a: Domain, b: Domain) bool {
    if (a.unknown or b.unknown) return false;
    return subset(a, b) or subset(b, a);
}

fn subset(a: Domain, b: Domain) bool {
    for (a.tags) |t| {
        if (!hasTag(b, t)) return false;
    }
    return true;
}

fn hasTag(d: Domain, t: []const u8) bool {
    for (d.tags) |u| {
        if (std.mem.eql(u8, u, t)) return true;
    }
    return false;
}

fn renderDomain(alloc: std.mem.Allocator, d: Domain) error{OutOfMemory}![]const u8 {
    if (d.unknown) return alloc.dupe(u8, "unresolved");
    if (d.tags.len == 0) return alloc.dupe(u8, "none");
    return std.mem.join(alloc, "+", d.tags);
}

fn fire(
    ctx: *context.Context,
    sc: usize,
    dc: usize,
    src_dom: Domain,
    dst_dom: Domain,
) error{OutOfMemory}!finding.Finding {
    const sname = ctx.mod.cells[sc].name;
    const dname = ctx.mod.cells[dc].name;
    const sdom = try renderDomain(ctx.tmp, src_dom);
    const ddom = try renderDomain(ctx.tmp, dst_dom);
    const message = try std.fmt.allocPrint(ctx.tmp, "unqualified data crossing reset domains: {s} (reset {s}) feeds {s} (reset {s}); the source can come out of reset while the receiver samples", .{ sname, sdom, dname, ddom });
    return .{
        .rule = rule.id,
        .severity = rule.severity,
        .dst = dname,
        .driver = sname,
        .message = message,
    };
}
