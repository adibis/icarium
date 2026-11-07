const std = @import("std");
const context = @import("context.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");
const reset = @import("../reset.zig");

pub const rule = registry.Rule{
    .id = "RDC-011",
    .severity = .err,
    .title = "One net drives both sync and async resets",
    .doc =
    \\One resolved reset root reaches an async pin on some flop
    \\and a sync control ($sdff SRST or a const-leg D-mux) on
    \\another. Async users leave reset on the net's edge while
    \\sync users wait for a clock, so the groups skew and their
    \\handoff corrupts. Split the net or qualify one side.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// Roots group by resolved origin: tied and unknown roots are
// not shared nets, so they never meet across the sides.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var groups = std.StringHashMapUnmanaged(Sides).empty;
    for (ctx.reset_view.flops) |fr| {
        const name = ctx.mod.cells[fr.cell].name;
        for (fr.async) |ar| {
            if (!isNet(ar.origin)) continue;
            const g = try groups.getOrPut(ctx.tmp, try keyFor(ctx.tmp, ar.origin, ar.ref));
            if (!g.found_existing) g.value_ptr.* = .{};
            try pushDistinct(ctx.tmp, &g.value_ptr.async_users, name);
        }
        if (fr.sync.kind != .none and isNet(fr.sync.origin)) {
            const g = try groups.getOrPut(ctx.tmp, try keyFor(ctx.tmp, fr.sync.origin, fr.sync.origin_ref));
            if (!g.found_existing) g.value_ptr.* = .{};
            try pushDistinct(ctx.tmp, &g.value_ptr.sync_users, name);
        }
    }
    var keys = std.ArrayListUnmanaged([]const u8).empty;
    var git = groups.iterator();
    while (git.next()) |e| {
        if (e.value_ptr.async_users.items.len > 0 and e.value_ptr.sync_users.items.len > 0)
            try keys.append(ctx.tmp, e.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    for (keys.items) |k| {
        const sides = groups.get(k).?;
        const cut = std.mem.indexOfScalar(u8, k, 0).?;
        const ja = try joinNames(ctx.tmp, sides.async_users.items);
        const js = try joinNames(ctx.tmp, sides.sync_users.items);
        const both = overlap(sides);
        const both_clause = if (both == 0) "" else try std.fmt.allocPrint(ctx.tmp, "; {d} flop{s} take it both ways", .{ both, if (both == 1) "" else "s" });
        const message = try std.fmt.allocPrint(ctx.tmp, "net '{s}' ({s}) drives async reset of {s} and sync reset of {s}{s}. Async users leave reset on the net's edge while sync users wait for a clock edge, so the two groups never leave reset together; split the net or qualify one side.", .{ k[cut + 1 ..], k[0..cut], ja, js, both_clause });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = sides.async_users.items[0],
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

const Sides = struct {
    async_users: std.ArrayListUnmanaged([]const u8) = .empty,
    sync_users: std.ArrayListUnmanaged([]const u8) = .empty,
};

fn isNet(o: reset.trace.Origin) bool {
    return o != .unknown and o != .constant;
}

fn keyFor(alloc: std.mem.Allocator, o: reset.trace.Origin, ref: []const u8) error{OutOfMemory}![]const u8 {
    const tag = @tagName(o);
    const out = try alloc.alloc(u8, tag.len + 1 + ref.len);
    @memcpy(out[0..tag.len], tag);
    out[tag.len] = 0;
    @memcpy(out[tag.len + 1 ..], ref);
    return out;
}

fn pushDistinct(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), v: []const u8) error{OutOfMemory}!void {
    for (list.items) |e| {
        if (e.ptr == v.ptr and e.len == v.len) return;
    }
    try list.append(alloc, v);
}

// Shared cell names, not shared pointers: the two sides may
// hold different slices of one flop's name.
fn overlap(s: Sides) usize {
    var n: usize = 0;
    for (s.async_users.items) |a| {
        for (s.sync_users.items) |b| {
            if (std.mem.eql(u8, a, b)) n += 1;
        }
    }
    return n;
}

// Four names read; the rest count. Small lists, linear join.
fn joinNames(alloc: std.mem.Allocator, names: []const []const u8) error{OutOfMemory}![]const u8 {
    const show = @min(names.len, 4);
    var total: usize = 0;
    for (names[0..show]) |n| total += n.len + 2;
    var extra: []const u8 = "";
    if (names.len > show) extra = try std.fmt.allocPrint(alloc, ", +{d} more", .{names.len - show});
    const out = try alloc.alloc(u8, total -| 2 + extra.len);
    var off: usize = 0;
    for (names[0..show], 0..) |n, i| {
        if (i > 0) {
            out[off] = ',';
            out[off + 1] = ' ';
            off += 2;
        }
        @memcpy(out[off..][0..n.len], n);
        off += n.len;
    }
    @memcpy(out[off..][0..extra.len], extra);
    return out;
}
