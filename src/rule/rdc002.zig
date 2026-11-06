const std = @import("std");
const bus = @import("bus.zig");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");
const reset = @import("../reset.zig");

pub const rule = registry.Rule{
    .id = "RDC-002",
    .severity = .err,
    .title = "Reset polarity mismatch on async reset distribution",
    .doc =
    \\A flop's async reset disagrees with its source: a producer
    \\flop drives a value the consumer never treats as assert, or a
    \\port declaration contradicts the pin. The consumer never
    \\enters reset when the source does. Add an inverter, or fix
    \\the edge to match the declaration.
    ,
    .honors = &.{"reset_sync"},
    .check_all = checkAll,
};

// Two grouped variants: flop-driven ARST pins whose producer
// value mismatches consumer sense, and port-driven pins whose
// declaration contradicts it. Resetless producers have no value
// to disagree with. Groups sort for determinism.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var groups = std.AutoHashMapUnmanaged(FGroup, Dsts).empty;
    var port_groups = std.HashMapUnmanaged(PGroup, Dsts, PGroupCtx, std.hash_map.default_max_load_percentage).empty;
    for (ctx.mod.cells) |c| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        // Stages exempt as consumers: their ARST is chain-internal.
        // Sync outputs driving foreign pins still answer below.
        if (ctx.reset_syncs.isMember(c.name)) continue;
        const ap = reset.cells.canonicalAsyncPin(c) orelse continue;
        const arst = bus.portBits(c, ap.pin) orelse continue;
        if (arst.len == 0 or arst[0] != .sig) continue;
        const cons: u8 = if (reset.chains.paramPolarity(c, ap.pin) == .high) '1' else '0';
        const drv = ctx.mod.driver_of.get(arst[0].sig) orelse continue;
        const di = drv.cell orelse {
            const declared = ctx.marks.resetPolarity(drv.port) orelse continue;
            const decl: u8 = if (declared == .high) '1' else '0';
            if (decl == cons) continue;
            const slot = try port_groups.getOrPut(ctx.tmp, .{ .port = drv.port, .decl = decl, .cons = cons });
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.put(ctx.tmp, c.name, {});
            continue;
        };
        if (!std.mem.eql(u8, drv.port, "Q")) continue;
        const prod = producerValue(ctx.mod.cells[di]) orelse continue;
        if (prod == cons) continue;
        const slot = try groups.getOrPut(ctx.tmp, .{ .producer = di, .prod = prod, .cons = cons });
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.put(ctx.tmp, c.name, {});
    }
    try emitFlopGroups(ctx, &groups, &out);
    try emitPortGroups(ctx, &port_groups, &out);
    return out.toOwnedSlice(ctx.tmp);
}

const FGroup = struct { producer: usize, prod: u8, cons: u8 };
const PGroup = struct { port: []const u8, decl: u8, cons: u8 };
const Dsts = std.StringHashMapUnmanaged(void);

// Content-hashed port triple: the default auto-hash refuses
// structs holding slices, so the group carries its own context.
const PGroupCtx = struct {
    pub fn hash(_: PGroupCtx, k: PGroup) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.port);
        h.update(&.{ k.decl, k.cons });
        return h.final();
    }
    pub fn eql(_: PGroupCtx, a: PGroup, b: PGroup) bool {
        return std.mem.eql(u8, a.port, b.port) and a.decl == b.decl and a.cons == b.cons;
    }
};

fn emitFlopGroups(
    ctx: *context.Context,
    groups: *const std.AutoHashMapUnmanaged(FGroup, Dsts),
    out: *std.ArrayListUnmanaged(finding.Finding),
) error{OutOfMemory}!void {
    var keys = std.ArrayListUnmanaged(FGroup).empty;
    var git = groups.iterator();
    while (git.next()) |e| try keys.append(ctx.tmp, e.key_ptr.*);
    std.mem.sort(FGroup, keys.items, ctx, struct {
        fn less(cx: *context.Context, a: FGroup, b: FGroup) bool {
            const ak = std.mem.order(u8, cx.mod.cells[a.producer].name, cx.mod.cells[b.producer].name);
            if (ak != .eq) return ak == .lt;
            if (a.prod != b.prod) return a.prod < b.prod;
            return a.cons < b.cons;
        }
    }.less);
    for (keys.items) |k| {
        const names = try sortedNames(ctx, groups.get(k).?);
        const desc = try dstDesc(ctx, names, "destination flop: {s}", "destination flops share this polarity mismatch from the same source (reset distribution tree): ");
        const message = try std.fmt.allocPrint(ctx.tmp,
            "reset polarity mismatch: consumer flop(s) expect reset asserted on '{c}' (ARST_POLARITY={c}), but the producer flop {s} drives its reset to '{c}' on assert (ARST_VALUE={c}); consumer(s) will never enter reset when the producer does. Add an inverter between them, or flip the consumer's reset edge sensitivity to match. {s}",
            .{ k.cons, k.cons, ctx.mod.cells[k.producer].name, k.prod, k.prod, desc });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = names[0],
            .message = message,
        });
    }
}

fn emitPortGroups(
    ctx: *context.Context,
    groups: *const std.HashMapUnmanaged(PGroup, Dsts, PGroupCtx, std.hash_map.default_max_load_percentage),
    out: *std.ArrayListUnmanaged(finding.Finding),
) error{OutOfMemory}!void {
    var keys = std.ArrayListUnmanaged(PGroup).empty;
    var git = groups.iterator();
    while (git.next()) |e| try keys.append(ctx.tmp, e.key_ptr.*);
    std.mem.sort(PGroup, keys.items, {}, struct {
        fn less(_: void, a: PGroup, b: PGroup) bool {
            const ak = std.mem.order(u8, a.port, b.port);
            if (ak != .eq) return ak == .lt;
            if (a.decl != b.decl) return a.decl < b.decl;
            return a.cons < b.cons;
        }
    }.less);
    for (keys.items) |k| {
        const names = try sortedNames(ctx, groups.get(k).?);
        const declared: []const u8 = if (k.decl == '1') "high" else "low";
        const wired: []const u8 = if (k.cons == '1') "high" else "low";
        const desc = try dstDesc(ctx, names, "destination flop: {s}", "destination flops disagree with the port-declared polarity: ");
        const message = try std.fmt.allocPrint(ctx.tmp,
            "reset polarity mismatch with port-level declaration: port '{s}' is annotated (* reset_polarity = \"{s}\" *) (active-{s}, asserts on '{c}'), but the consumer flop(s) are wired active-{s} (ARST_POLARITY={c}); the declared port polarity disagrees with the flop's reset edge sensitivity. Fix the flop's edge to match the port declaration, or remove the (* reset_polarity *) attribute if the declaration is wrong. {s}",
            .{ k.port, declared, declared, k.decl, wired, k.cons, desc });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = names[0],
            .message = message,
        });
    }
}

fn sortedNames(ctx: *context.Context, dsts: Dsts) error{OutOfMemory}![][]const u8 {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    var dit = dsts.iterator();
    while (dit.next()) |de| try names.append(ctx.tmp, de.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return names.toOwnedSlice(ctx.tmp);
}

// One consumer reads bare with its prefix; crowds read as a
// count sharing the group's prefix, then a three-name sample.
fn dstDesc(ctx: *context.Context, names: [][]const u8, comptime one_fmt: []const u8, group_prefix: []const u8) error{OutOfMemory}![]const u8 {
    if (names.len == 1) return std.fmt.allocPrint(ctx.tmp, one_fmt, .{names[0]});
    var buf = std.ArrayListUnmanaged(u8).empty;
    const head = try std.fmt.allocPrint(ctx.tmp, "{d} {s}", .{ names.len, group_prefix });
    try buf.appendSlice(ctx.tmp, head);
    const show = @min(names.len, 3);
    for (names[0..show], 0..) |n, i| {
        if (i > 0) try buf.appendSlice(ctx.tmp, ", ");
        try buf.appendSlice(ctx.tmp, n);
    }
    if (names.len > 3) try buf.appendSlice(ctx.tmp, ", ...");
    return buf.toOwnedSlice(ctx.tmp);
}

// The value a producer flop drives from async reset: ARST_VALUE
// trailing bit on async flops, zero on set/reset flops. Plain
// flops and sync-only flops have no async value to compare.
fn producerValue(c: ir.types.Cell) ?u8 {
    if (std.mem.eql(u8, c.type, "$adff") or std.mem.eql(u8, c.type, "$adffe")) {
        for (c.params) |p| {
            if (!std.mem.eql(u8, p.name, "ARST_VALUE")) continue;
            if (p.value != .str) return '0';
            return trailingBit(p.value.str);
        }
        return '0';
    }
    if (std.mem.eql(u8, c.type, "$dffsr") or std.mem.eql(u8, c.type, "$dffsre")) return '0';
    return null;
}

fn trailingBit(raw: []const u8) u8 {
    if (raw.len == 0) return '0';
    const last = raw[raw.len - 1];
    return if (last == '0' or last == '1') last else '0';
}
