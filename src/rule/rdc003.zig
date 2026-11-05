const std = @import("std");
const bus = @import("bus.zig");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");
const reset = @import("../reset.zig");

pub const rule = registry.Rule{
    .id = "RDC-003",
    .severity = .err,
    .title = "Sync reset driven from a foreign async domain",
    .doc =
    \\A flop's synchronous reset fans in from a register in another
    \\clock domain. The sync reset samples on the destination edge,
    \\so a foreign source turns deassertion into a metastability
    \\lottery. Synchronize the reset into the consumer domain.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// The SRST analogue of the RDC-001 ARST walk: backward fanin
// from every sync reset, grouped by (source, src clock, dst
// clock) so one foreign source reads as one finding. Both
// spellings count: the SRST pin on folded cells and the mux
// select on the no-opt flow, which never folds muxes away.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var by_cell = std.AutoHashMapUnmanaged(usize, *const reset.trace.FlopReset).empty;
    for (ctx.reset_view.flops) |*fr| try by_cell.put(ctx.alloc, fr.cell, fr);
    var groups = std.HashMapUnmanaged(Group, Dsts, GroupCtx, std.hash_map.default_max_load_percentage).empty;
    for (ctx.mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        const dom = ctx.table.domainOf(ci) orelse continue;
        if (std.mem.eql(u8, dom.name, "unknown")) continue;
        const bits = syncResetBits(ctx, &by_cell, ci) orelse continue;
        const fanin = try context.backwardFlopFanin(ctx.alloc, ctx.mod, bits);
        for (fanin.items) |f| {
            const fdom = ctx.table.domainOf(f) orelse continue;
            if (std.mem.eql(u8, fdom.name, "unknown")) continue;
            if (std.mem.eql(u8, fdom.name, dom.name)) continue;
            if (!ctx.model.areAsync(dom.name, fdom.name)) continue;
            const key = Group{ .src = f, .src_clk = fdom.name, .dst_clk = dom.name };
            const slot = try groups.getOrPut(ctx.alloc, key);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.put(ctx.alloc, ctx.mod.cells[ci].name, {});
        }
    }
    var keys = std.ArrayListUnmanaged(Group).empty;
    var git = groups.iterator();
    while (git.next()) |e| try keys.append(ctx.alloc, e.key_ptr.*);
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
        while (dit.next()) |de| try names.append(ctx.alloc, de.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        const desc = try dstDesc(ctx, names.items);
        const message = try std.fmt.allocPrint(ctx.alloc,
            "sync reset crossing: flop(s) in clk={s} have SRST driven by flop {s} from a different async domain (clk={s}); the sync reset is sampled on the destination clock and the cross-domain source may produce metastability. Add a 2FF reset synchroniser in the {s} domain. {s}",
            .{ k.dst_clk, ctx.mod.cells[k.src].name, k.src_clk, k.dst_clk, desc });
        try out.append(ctx.alloc, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = names.items[0],
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.alloc);
}

// Sync reset stimulus bits in either spelling: the SRST pin
// where folding produced one, else the reset mux's select.
fn syncResetBits(
    ctx: *context.Context,
    by_cell: *const std.AutoHashMapUnmanaged(usize, *const reset.trace.FlopReset),
    ci: usize,
) ?[]ir.bits.Bit {
    const c = ctx.mod.cells[ci];
    if (bus.portBits(c, "SRST")) |srst| {
        if (srst.len > 0) return srst;
    }
    const fr = by_cell.get(ci) orelse return null;
    if (fr.sync.kind != .mux) return null;
    const mi = fr.sync.mux orelse return null;
    const s = bus.portBits(ctx.mod.cells[mi], "S") orelse return null;
    if (s.len == 0) return null;
    return s;
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

// One consumer reads bare; crowds read as a count sharing the
// source, then a three-name sample.
fn dstDesc(ctx: *context.Context, names: [][]const u8) error{OutOfMemory}![]const u8 {
    if (names.len == 1) return std.fmt.allocPrint(ctx.alloc, "destination flop: {s}", .{names[0]});
    var buf = std.ArrayListUnmanaged(u8).empty;
    const head = try std.fmt.allocPrint(ctx.alloc, "{d} destination flops share this source (reset distribution tree): ", .{names.len});
    try buf.appendSlice(ctx.alloc, head);
    const show = @min(names.len, 3);
    for (names[0..show], 0..) |n, i| {
        if (i > 0) try buf.appendSlice(ctx.alloc, ", ");
        try buf.appendSlice(ctx.alloc, n);
    }
    if (names.len > 3) try buf.appendSlice(ctx.alloc, ", ...");
    return buf.toOwnedSlice(ctx.alloc);
}
