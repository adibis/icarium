const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");
const reset = @import("../reset.zig");

pub const rule = registry.Rule{
    .id = "RDC-008",
    .severity = .err,
    .title = "Primary reset port unsynchronized in one domain",
    .doc =
    \\A top-level reset port fans straight into flops of a domain
    \\with no reset synchronizer, while another domain syncs the
    \\same port: the builder knew, then missed a domain. Sync the
    \\port in every consuming domain. Silent when every domain
    \\uses the raw port; that simplification is a separate review.
    ,
    .honors = &.{"reset_sync"},
    .check_all = checkAll,
};

// One finding per (port, clock) with two or more direct port-fed
// consumers: lone flops read as judgement calls, crowds as a
// missing distribution stage. The asymmetry gate (a chain for
// this port must exist elsewhere) separates bugs from style.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var by_cell = std.AutoHashMapUnmanaged(usize, *const reset.trace.FlopReset).empty;
    for (ctx.reset_view.flops) |*fr| try by_cell.put(ctx.tmp, fr.cell, fr);
    var groups = std.HashMapUnmanaged(Group, Dsts, GroupCtx, std.hash_map.default_max_load_percentage).empty;
    for (ctx.mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        if (ctx.reset_syncs.isMember(c.name)) continue;
        const fr = by_cell.get(ci) orelse continue;
        const dom = ctx.table.domainOf(ci) orelse continue;
        if (std.mem.eql(u8, dom.name, "unknown")) continue;
        for (fr.async) |ar| {
            if (ar.origin != .port) continue;
            const key = Group{ .port = ar.ref, .clk = dom.name };
            const slot = try groups.getOrPut(ctx.tmp, key);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.put(ctx.tmp, c.name, {});
        }
    }
    const synced = try syncedClocks(ctx, &by_cell);
    var keys = std.ArrayListUnmanaged(Group).empty;
    var git = groups.iterator();
    while (git.next()) |e| try keys.append(ctx.tmp, e.key_ptr.*);
    std.mem.sort(Group, keys.items, {}, struct {
        fn less(_: void, a: Group, b: Group) bool {
            const ak = std.mem.order(u8, a.port, b.port);
            if (ak != .eq) return ak == .lt;
            return std.mem.order(u8, a.clk, b.clk) == .lt;
        }
    }.less);
    for (keys.items) |k| {
        if (!synced.contains(k.port)) continue;
        const dsts = groups.get(k).?;
        var names = std.ArrayListUnmanaged([]const u8).empty;
        var dit = dsts.iterator();
        while (dit.next()) |de| try names.append(ctx.tmp, de.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        if (names.items.len < 2) continue;
        const desc = try dstDesc(ctx, names.items);
        const message = try std.fmt.allocPrint(ctx.tmp,
            "unsynced primary-reset port: top-level reset port '{s}' drives {s} in {s} directly, with no reset-synchronizer chain in that clock domain. Reset assertion is fine, but the deassertion edge is unsynchronized to the consumer clock: recovery/removal timing violations can leave random subsets of flops in different reset states. Add a 2FF reset-synchronizer chain in {s} whose ARST is '{s}', and route consumers through the chain's tail.",
            .{ k.port, desc, k.clk, k.clk, k.port });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = names.items[0],
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

// Ports with sync infrastructure somewhere: every member's own
// port-fed ARST is a chain input, user marks included, since a
// vouched flop is still evidence the port needs syncing.
fn syncedClocks(
    ctx: *context.Context,
    by_cell: *const std.AutoHashMapUnmanaged(usize, *const reset.trace.FlopReset),
) error{OutOfMemory}!std.StringHashMapUnmanaged(void) {
    var synced = std.StringHashMapUnmanaged(void).empty;
    for (ctx.mod.cells, 0..) |c, ci| {
        if (!ctx.reset_syncs.isMember(c.name)) continue;
        const fr = by_cell.get(ci) orelse continue;
        for (fr.async) |ar| {
            if (ar.origin != .port) continue;
            try synced.put(ctx.tmp, ar.ref, {});
        }
    }
    return synced;
}

const Group = struct { port: []const u8, clk: []const u8 };
const Dsts = std.StringHashMapUnmanaged(void);

// Content-hashed pair: the default auto-hash refuses structs
// holding slices, so the group carries its own context.
const GroupCtx = struct {
    pub fn hash(_: GroupCtx, k: Group) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.port);
        h.update("\x00");
        h.update(k.clk);
        return h.final();
    }
    pub fn eql(_: GroupCtx, a: Group, b: Group) bool {
        return std.mem.eql(u8, a.port, b.port) and std.mem.eql(u8, a.clk, b.clk);
    }
};

// Crowds read as a count with a sample; singles never reach here.
fn dstDesc(ctx: *context.Context, names: [][]const u8) error{OutOfMemory}![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    const head = try std.fmt.allocPrint(ctx.tmp, "{d} flops (", .{names.len});
    try buf.appendSlice(ctx.tmp, head);
    const show = @min(names.len, 3);
    for (names[0..show], 0..) |n, i| {
        if (i > 0) try buf.appendSlice(ctx.tmp, ", ");
        try buf.appendSlice(ctx.tmp, n);
    }
    if (names.len > 3) try buf.appendSlice(ctx.tmp, "...");
    try buf.appendSlice(ctx.tmp, ")");
    return buf.toOwnedSlice(ctx.tmp);
}
