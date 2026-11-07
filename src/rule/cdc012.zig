const std = @import("std");
const bus = @import("bus.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-012",
    .severity = .warn,
    .title = "Gated bus crossing without synced-back handshake",
    .doc =
    \\A gated multi-bit crossing has no handshake holding the
    \\payload: the destination latches cycles after the request,
    \\by which time the source may have moved on. Hold the source
    \\payload until a synced-back ack confirms the sample.
    ,
    .honors = &.{ "cdc_gray", "cdc_handshake" },
    .check_all = checkAll,
};

// Gated multi-bit flop buses whose source register shows no
// dst-domain feedback within six flop hops. Gray sources and
// vouched handshakes exempt: both hold the payload by shape.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var feedback = std.AutoHashMapUnmanaged(usize, std.StringHashMapUnmanaged(bool)).empty;
    var fanin = std.AutoHashMapUnmanaged(usize, []usize).empty;
    for (ctx.crossings) |x| {
        if (x.kind != .flop_flop_bus) continue;
        if (std.mem.eql(u8, x.src_clk, "unknown")) continue;
        // Unresolved destinations belong to CDC-025: the fanin
        // walks below retain per pair, which dominates memory.
        if (std.mem.eql(u8, x.dst_clk, "unknown")) continue;
        if (std.mem.eql(u8, x.src_clk, x.dst_clk)) continue;
        const sc = x.src.cell orelse continue;
        const dc = x.dst.cell orelse continue;
        // Muxed endpoints belong to the leg-pair report: gating
        // and feedback need one exact domain on each side.
        if (bus.isMuxedClock(ctx, sc) or bus.isMuxedClock(ctx, dc)) continue;
        if (!(try bus.isGatedBusCrossing(ctx, dc, x.dst_clk))) continue;
        const src_name = ctx.mod.cells[sc].name;
        if (ctx.marks.hasGray(src_name)) continue;
        if (bus.isGrayEncodedSource(ctx, sc)) continue;
        if (ctx.marks.hasHandshake(src_name)) continue;
        if (ctx.marks.hasHandshake(ctx.mod.cells[dc].name)) continue;
        // Feedback keys by source and clock pair: the verdict
        // answers for one domain pair, and sharing it across
        // pairs both misreports and depends on arrival order.
        const fop = try feedback.getOrPut(ctx.tmp, sc);
        if (!fop.found_existing) fop.value_ptr.* = .empty;
        const fkey = try std.fmt.allocPrint(ctx.tmp, "{s}|{s}", .{ x.src_clk, x.dst_clk });
        const gop = try fop.value_ptr.getOrPut(ctx.tmp, fkey);
        if (!gop.found_existing) gop.value_ptr.* = try hasFeedback(ctx, &fanin, sc, x.src_clk, x.dst_clk);
        if (gop.value_ptr.*) continue;
        const message = try std.fmt.allocPrint(ctx.tmp, "functional data-hold risk on '{s}' -> '{s}': {d}-bit gated bus crossing from '{s}' to '{s}' has no synced-back handshake between the two domains. The destination's enable is synchronised, but nothing keeps the source payload stable while the enable is in flight. Add a req/ack handshake: hold the source payload until an ack from the destination confirms the sample.", .{ src_name, ctx.mod.cells[dc].name, x.lanes.len, x.src_clk, x.dst_clk });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = src_name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

// Register-neighbourhood walk from the source, hopping through
// same-src-clock flops: reaching a dst-clock flop proves the
// source can hear the destination. Cached per source flop.
fn hasFeedback(
    ctx: *context.Context,
    fanin_cache: *std.AutoHashMapUnmanaged(usize, []usize),
    src: usize,
    src_clock: []const u8,
    dst_clock: []const u8,
) error{OutOfMemory}!bool {
    var seen = std.AutoHashMapUnmanaged(usize, void).empty;
    try seen.put(ctx.tmp, src, {});
    var frontier = std.ArrayListUnmanaged(usize).empty;
    try frontier.append(ctx.tmp, src);
    for (0..6) |_| {
        var next = std.ArrayListUnmanaged(usize).empty;
        for (frontier.items) |f| {
            const fanin = try cachedFanin(ctx, fanin_cache, f);
            for (fanin) |ff| {
                if (seen.contains(ff)) continue;
                try seen.put(ctx.tmp, ff, {});
                const dom = ctx.table.domainOf(ff) orelse continue;
                if (std.mem.eql(u8, dom.name, dst_clock)) return true;
                if (std.mem.eql(u8, dom.name, src_clock)) try next.append(ctx.tmp, ff);
            }
        }
        if (next.items.len == 0) break;
        frontier = next;
    }
    return false;
}

fn cachedFanin(
    ctx: *context.Context,
    fanin_cache: *std.AutoHashMapUnmanaged(usize, []usize),
    f: usize,
) error{OutOfMemory}![]usize {
    if (fanin_cache.get(f)) |hit| return hit;
    var bits = std.ArrayListUnmanaged(ir.bits.Bit).empty;
    for (ctx.mod.cells[f].ports) |p| {
        if (p.direction == .output) continue;
        if (std.mem.eql(u8, p.name, "CLK") or std.mem.eql(u8, p.name, "C")) continue;
        for (p.bits) |b| {
            if (b == .sig) try bits.append(ctx.tmp, b);
        }
    }
    var fanin = try context.backwardFlopFanin(ctx.tmp, ctx.mod, bits.items);
    const owned = try fanin.toOwnedSlice(ctx.tmp);
    try fanin_cache.put(ctx.tmp, f, owned);
    return owned;
}
