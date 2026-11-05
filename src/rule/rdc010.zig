const std = @import("std");
const bus = @import("bus.zig");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");
const reset = @import("../reset.zig");

pub const rule = registry.Rule{
    .id = "RDC-010",
    .severity = .note,
    .title = "Reset synchronizer chain record and checks",
    .doc =
    \\Every recognized reset synchronizer is recorded for review:
    \\stages, clock, polarity, head constant, async root. Shape
    \\defects report beside the record: a chain on the wrong clock
    \\for its consumers, internal taps feeding resets, and gates
    \\editing the output all break the release contract; consumers
    \\on the raw root in a served domain report at warn.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// One forward walk per chain Q through combinational loads;
// chains are few, so one scratch arena serves the whole rule and
// only findings survive into the caller arena. Every load
// bit is visited once per walk, twelve hops bound each cone.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var scratch = std.heap.ArenaAllocator.init(ctx.alloc);
    defer scratch.deinit();
    const alloc = scratch.allocator();
    var by_cell = std.AutoHashMapUnmanaged(usize, *const reset.trace.FlopReset).empty;
    for (ctx.reset_view.flops) |*fr| try by_cell.put(alloc, fr.cell, fr);
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    for (ctx.reset_syncs.chains) |ch| {
        const tail = ch.flops[0];
        const dom = ctx.table.domainOf(tail) orelse continue;
        if (std.mem.eql(u8, dom.name, "unknown")) continue;
        const tfr = by_cell.get(tail) orelse continue;
        const tar = asyncOf(ctx.mod.cells[tail], tfr) orelse continue;
        const consumers = try reset.chains.asyncLoads(alloc, ctx.mod, tail);
        sortLoads(ctx.mod, consumers);
        try out.append(ctx.alloc, try noteChain(ctx, ch, dom.name, tar, consumers.len));
        var cset = std.AutoHashMapUnmanaged(usize, void).empty;
        for (consumers) |cl| {
            try cset.put(alloc, cl.cell, {});
            if (cl.via_comb) try out.append(ctx.alloc, try fireComb(ctx, tail, cl));
            const cdom = ctx.table.domainOf(cl.cell) orelse continue;
            if (std.mem.eql(u8, cdom.name, "unknown")) continue;
            if (!std.mem.eql(u8, cdom.name, dom.name)) try out.append(ctx.alloc, try fireClock(ctx, tail, cl.cell, dom.name, cdom.name));
        }
        for (ch.flops[1..]) |stage| {
            const taps = try reset.chains.asyncLoads(alloc, ctx.mod, stage);
            sortLoads(ctx.mod, taps);
            for (taps) |tap| {
                if (ctx.reset_syncs.isMember(ctx.mod.cells[tap.cell].name)) continue;
                try out.append(ctx.alloc, try fireTap(ctx, tail, stage, tap.cell));
            }
        }
        if (tar.origin == .port) {
            for (ctx.reset_view.flops) |*fr| {
                if (fr.cell == tail or cset.contains(fr.cell)) continue;
                if (ctx.reset_syncs.isMember(ctx.mod.cells[fr.cell].name)) continue;
                if (!std.mem.eql(u8, fr.clock.name, dom.name)) continue;
                const far = asyncOf(ctx.mod.cells[fr.cell], fr) orelse continue;
                if (far.origin != .port or !std.mem.eql(u8, far.ref, tar.ref)) continue;
                try out.append(ctx.alloc, try fireRaw(ctx, tail, fr.cell, dom.name, tar.ref));
            }
        }
    }
    return out.toOwnedSlice(ctx.alloc);
}

fn sortLoads(mod: *const ir.types.Module, loads: []reset.chains.Load) void {
    std.mem.sort(reset.chains.Load, loads, mod, struct {
        fn less(m: *const ir.types.Module, a: reset.chains.Load, b: reset.chains.Load) bool {
            return std.mem.order(u8, m.cells[a.cell].name, m.cells[b.cell].name) == .lt;
        }
    }.less);
}

fn asyncOf(c: ir.types.Cell, fr: *const reset.trace.FlopReset) ?reset.trace.AsyncReset {
    const want = reset.cells.canonicalAsyncPin(c) orelse return null;
    for (fr.async) |ar| {
        if (std.mem.eql(u8, ar.pin, want.pin)) return ar;
    }
    return null;
}

fn noteChain(
    ctx: *context.Context,
    ch: reset.chains.Chain,
    clk: []const u8,
    tar: reset.trace.AsyncReset,
    ncon: usize,
) error{OutOfMemory}!finding.Finding {
    const tail = ctx.mod.cells[ch.flops[0]].name;
    const head = ctx.mod.cells[ch.flops[ch.flops.len - 1]].name;
    const word: []const u8 = if (ch.polarity == .high) "active-high" else "active-low";
    const dc: u8 = switch (ch.head_d) {
        .one => '1',
        .zero => '0',
        else => '?',
    };
    const message = try std.fmt.allocPrint(ctx.alloc,
        "reset synchronizer {s} <- {s} ({d} stages) on {s}, {s}, head D '{c}', async root {s}; serves {d} on-chip consumer{s}",
        .{ tail, head, ch.flops.len, clk, word, dc, tar.ref, ncon, if (ncon == 1) "" else "s" });
    return .{
        .rule = rule.id,
        .severity = .note,
        .dst = tail,
        .message = message,
    };
}

fn fireClock(
    ctx: *context.Context,
    tail: usize,
    consumer: usize,
    clk: []const u8,
    cclk: []const u8,
) error{OutOfMemory}!finding.Finding {
    const message = try std.fmt.allocPrint(ctx.alloc,
        "reset synchronizer {s} runs on {s} but drives the async reset of {s} on {s}: the release edge arrives in the wrong clock domain and races the consumer clock",
        .{ ctx.mod.cells[tail].name, clk, ctx.mod.cells[consumer].name, cclk });
    return .{
        .rule = rule.id,
        .severity = .err,
        .dst = ctx.mod.cells[consumer].name,
        .driver = ctx.mod.cells[tail].name,
        .message = message,
    };
}

fn fireTap(
    ctx: *context.Context,
    tail: usize,
    stage: usize,
    consumer: usize,
) error{OutOfMemory}!finding.Finding {
    const message = try std.fmt.allocPrint(ctx.alloc,
        "consumer {s} takes its async reset from internal tap {s} of reset synchronizer {s} instead of the final stage: the tap releases early with less settling time",
        .{ ctx.mod.cells[consumer].name, ctx.mod.cells[stage].name, ctx.mod.cells[tail].name });
    return .{
        .rule = rule.id,
        .severity = .err,
        .dst = ctx.mod.cells[consumer].name,
        .driver = ctx.mod.cells[stage].name,
        .message = message,
    };
}

fn fireComb(
    ctx: *context.Context,
    tail: usize,
    cl: reset.chains.Load,
) error{OutOfMemory}!finding.Finding {
    const message = try std.fmt.allocPrint(ctx.alloc,
        "combinational {s} sits between reset synchronizer {s} and consumer {s}: the gate can glitch or skew the release edge the chain shaped",
        .{ ctx.mod.cells[cl.comb].name, ctx.mod.cells[tail].name, ctx.mod.cells[cl.cell].name });
    return .{
        .rule = rule.id,
        .severity = .err,
        .dst = ctx.mod.cells[cl.cell].name,
        .driver = ctx.mod.cells[tail].name,
        .message = message,
    };
}

fn fireRaw(
    ctx: *context.Context,
    tail: usize,
    consumer: usize,
    clk: []const u8,
    root: []const u8,
) error{OutOfMemory}!finding.Finding {
    const message = try std.fmt.allocPrint(ctx.alloc,
        "consumer {s} on {s} uses raw reset {s} while reset synchronizer {s} serves the same root and clock: its release runs ahead of the synchronized consumers",
        .{ ctx.mod.cells[consumer].name, clk, root, ctx.mod.cells[tail].name });
    return .{
        .rule = rule.id,
        .severity = .warn,
        .dst = ctx.mod.cells[consumer].name,
        .driver = ctx.mod.cells[tail].name,
        .message = message,
    };
}
