const std = @import("std");
const bus = @import("bus.zig");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "RDC-001",
    .severity = .err,
    .title = "Async reset released from a foreign clock domain",
    .doc =
    \\A flop's async reset fans in from a register in another clock
    \\domain: every foreign deassertion races the local clock, so
    \\the flop never reaches a clean out-of-reset state. Reset it
    \\from its own domain's tree, or synchronize the reset across.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// One finding per (source, src clock, dst clock): the ARST fanin
// of every flopped reset source async to its consumer. Ports
// and constants pass; only clocked foreign logic reports.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var groups = std.HashMapUnmanaged(Group, Dsts, GroupCtx, std.hash_map.default_max_load_percentage).empty;
    for (ctx.mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        const dom = ctx.table.domainOf(ci) orelse continue;
        if (std.mem.eql(u8, dom.name, "unknown")) continue;
        const arst = bus.portBits(c, "ARST") orelse continue;
        if (arst.len == 0) continue;
        const fanin = try context.backwardFlopFanin(ctx.tmp, ctx.mod, arst);
        for (fanin.items) |f| {
            const fdom = ctx.table.domainOf(f) orelse continue;
            if (std.mem.eql(u8, fdom.name, "unknown")) continue;
            if (std.mem.eql(u8, fdom.name, dom.name)) continue;
            if (!ctx.model.areAsync(fdom.name, dom.name)) continue;
            const key = Group{ .src = f, .src_clk = fdom.name, .dst_clk = dom.name };
            const slot = try groups.getOrPut(ctx.tmp, key);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.put(ctx.tmp, ctx.mod.cells[ci].name, {});
        }
    }
    var keys = std.ArrayListUnmanaged(Group).empty;
    var git = groups.iterator();
    while (git.next()) |e| try keys.append(ctx.tmp, e.key_ptr.*);
    std.mem.sort(Group, keys.items, ctx, struct {
        fn less(cx: *context.Context, a: Group, b: Group) bool {
            const ak = std.mem.order(u8, cx.mod.cells[a.src].name, cx.mod.cells[b.src].name);
            if (ak != .eq) return ak == .lt;
            const bk = std.mem.order(u8, a.src_clk, b.src_clk);
            if (bk != .eq) return bk == .lt;
            return std.mem.order(u8, a.dst_clk, b.dst_clk) == .lt;
        }
    }.less);
    for (keys.items) |k| {
        const dsts = groups.get(k).?;
        var names = std.ArrayListUnmanaged([]const u8).empty;
        var dit = dsts.iterator();
        while (dit.next()) |de| try names.append(ctx.tmp, de.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        const desc = try dstDesc(ctx, names.items);
        const message = try std.fmt.allocPrint(ctx.tmp, "async reset released from a foreign clock domain: ARST of {s} in clock domain '{s}' is driven by flop '{s}' in async clock domain '{s}'. An asynchronously-released reset races the destination clock and can leave the flop metastable coming out of reset. Drive the reset from the destination domain's reset tree, or pass it through a reset synchroniser in '{s}'.", .{ desc, k.dst_clk, ctx.mod.cells[k.src].name, k.src_clk, k.dst_clk });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = names.items[0],
            .driver = ctx.mod.cells[k.src].name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

const Group = struct { src: usize, src_clk: []const u8, dst_clk: []const u8 };
const Dsts = std.StringHashMapUnmanaged(void);

// Content-hashed triple: the default auto-hash refuses structs
// holding slices, so the group carries its own context.
const GroupCtx = struct {
    pub fn hash(_: GroupCtx, k: Group) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.src));
        h.update(k.src_clk);
        h.update("\x00");
        h.update(k.dst_clk);
        return h.final();
    }
    pub fn eql(_: GroupCtx, a: Group, b: Group) bool {
        return a.src == b.src and
            std.mem.eql(u8, a.src_clk, b.src_clk) and
            std.mem.eql(u8, a.dst_clk, b.dst_clk);
    }
};

// One consumer reads bare; crowds read as a count with a sample.
fn dstDesc(ctx: *context.Context, names: [][]const u8) error{OutOfMemory}![]const u8 {
    if (names.len == 1) return std.fmt.allocPrint(ctx.tmp, "flop '{s}'", .{names[0]});
    var buf = std.ArrayListUnmanaged(u8).empty;
    const head = try std.fmt.allocPrint(ctx.tmp, "{d} flops (", .{names.len});
    try buf.appendSlice(ctx.tmp, head);
    const show = @min(names.len, 3);
    for (names[0..show], 0..) |n, i| {
        if (i > 0) try buf.appendSlice(ctx.tmp, ", ");
        const one = try std.fmt.allocPrint(ctx.tmp, "'{s}'", .{n});
        try buf.appendSlice(ctx.tmp, one);
    }
    if (names.len > 3) try buf.appendSlice(ctx.tmp, ", ...");
    try buf.appendSlice(ctx.tmp, ")");
    return buf.toOwnedSlice(ctx.tmp);
}
