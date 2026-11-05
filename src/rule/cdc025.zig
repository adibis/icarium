const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");
const reset = @import("../reset.zig");
const sync = @import("../sync.zig");

pub const rule = registry.Rule{
    .id = "CDC-025",
    .severity = .warn,
    .title = "Unresolved clock association",
    .doc =
    \\A crossing endpoint has no clock association: undriven flop
    \\clock, macro or memory output, unhandled primitive, or an
    \\untyped input the other port rules do not own. One finding
    \\per endpoint names the reason and the fanout; per-pair sync
    \\verdicts on unclocked endpoints would be noise. Type the
    \\source, model the macro, or waive after review.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// Unclocked endpoints gather by endpoint; each fires once with its
// reason and fanout. CDC-011 owns untyped inputs into D/SRST of
// known flops, CDC-021 owns port:-clocked destinations; the rest
// of the dispatcher's unknown pairs land here, never nowhere.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var by_key = std.StringHashMapUnmanaged(Group).empty;
    for (ctx.report.crossings) |x| {
        if (!registry.unknownSide(x)) continue;
        if (x.kind == .flop_flop_bus or x.kind == .port_flop_bus) continue;
        if (ownedByCdc011(x)) continue;
        if (ownedByCdc021(x)) continue;
        // Reset ports are RDC jurisdiction: an untyped input driving
        // an async reset pin is reset intent, not a CDC unknown.
        if (x.src.cell == null and isAsyncResetPin(ctx, x)) continue;
        // Recognized synchronizer primitives are modeled cells, not
        // unknown macros: CDC-022 already reads their parameters.
        if (x.src.cell) |sc| {
            if (sync.primitives.isSyncPrimitive(ctx.mod.cells[sc].type, ctx.cfg.sync_primitives)) continue;
        }
        const key = groupKey(ctx, x) orelse continue;
        const slot = try by_key.getOrPut(ctx.alloc, key.name);
        if (!slot.found_existing) slot.value_ptr.* = .{ .cell = key.cell, .port = key.port };
        try slot.value_ptr.add(ctx.alloc, farName(ctx, x, key));
    }
    var keys = std.ArrayListUnmanaged([]const u8).empty;
    var it = by_key.iterator();
    while (it.next()) |e| try keys.append(ctx.alloc, e.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    for (keys.items) |k| {
        const g = by_key.get(k).?;
        try out.append(ctx.alloc, try fire(ctx, k, g));
    }
    return out.toOwnedSlice(ctx.alloc);
}

fn ownedByCdc011(x: crossing.enumerate.Crossing) bool {
    if (x.kind != .port_flop_untyped) return false;
    if (!std.mem.eql(u8, x.dst.port, "D") and !std.mem.eql(u8, x.dst.port, "SRST")) return false;
    return !std.mem.eql(u8, x.dst_clk, "unknown");
}

fn ownedByCdc021(x: crossing.enumerate.Crossing) bool {
    return std.mem.startsWith(u8, x.dst_clk, "port:");
}

fn isAsyncResetPin(ctx: *context.Context, x: crossing.enumerate.Crossing) bool {
    const dc = x.dst.cell orelse return false;
    const ap = reset.cells.canonicalAsyncPin(ctx.mod.cells[dc]) orelse return false;
    return std.mem.eql(u8, x.dst.port, ap.pin);
}

const Key = struct { name: []const u8, cell: ?usize, port: ?[]const u8 };

// The unclocked end owns the group; a port source only keys when
// the destination resolves, since CDC-011 takes the rest.
fn groupKey(ctx: *context.Context, x: crossing.enumerate.Crossing) ?Key {
    if (std.mem.eql(u8, x.dst_clk, "unknown")) {
        const dc = x.dst.cell orelse return null;
        return .{ .name = ctx.mod.cells[dc].name, .cell = dc, .port = null };
    }
    if (x.src.cell) |sc| {
        return .{ .name = ctx.mod.cells[sc].name, .cell = sc, .port = null };
    }
    return .{ .name = x.src.port, .cell = null, .port = x.src.port };
}

fn farName(ctx: *context.Context, x: crossing.enumerate.Crossing, key: Key) []const u8 {
    if (key.cell) |kc| {
        if (x.src.cell) |sc| {
            if (sc != kc) return ctx.mod.cells[sc].name;
        } else {
            return x.src.port;
        }
        const dc = x.dst.cell orelse return "?";
        if (dc != kc) return ctx.mod.cells[dc].name;
        return ctx.mod.cells[dc].name;
    }
    const dc = x.dst.cell orelse return "?";
    return ctx.mod.cells[dc].name;
}

const Group = struct {
    cell: ?usize,
    port: ?[]const u8,
    count: usize = 0,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    sample: std.ArrayListUnmanaged([]const u8) = .empty,

    fn add(self: *Group, alloc: std.mem.Allocator, far: []const u8) error{OutOfMemory}!void {
        self.count += 1;
        if (self.sample.items.len >= 4) return;
        const slot = try self.seen.getOrPut(alloc, far);
        if (slot.found_existing) return;
        try self.sample.append(alloc, far);
    }
};

// Structure first, tracer notes second: a macro output is a macro
// output whatever the clock walk concluded about its driver.
fn reason(ctx: *context.Context, g: Group) error{OutOfMemory}![]const u8 {
    if (g.port) |p| {
        return std.fmt.allocPrint(ctx.alloc, "untyped input port '{s}': no set_input_delay clock typing", .{p});
    }
    const ci = g.cell.?;
    const c = ctx.mod.cells[ci];
    if (c.blackbox) return std.fmt.allocPrint(ctx.alloc, "macro output '{s}': blackbox has no clock association", .{c.name});
    if (clock.cells.isMemRead(c.type)) return std.fmt.allocPrint(ctx.alloc, "memory read output '{s}': no clock association", .{c.name});
    if (ctx.table.domainOf(ci)) |d| {
        if (d.notes.len > 0) return std.mem.join(ctx.alloc, "; ", d.notes);
    }
    return std.fmt.allocPrint(ctx.alloc, "endpoint '{s}': clock association unresolved", .{c.name});
}

fn fire(ctx: *context.Context, key: []const u8, g: Group) error{OutOfMemory}!finding.Finding {
    const why = try reason(ctx, g);
    const sample = try std.mem.join(ctx.alloc, ", ", g.sample.items);
    const dst = if (g.cell) |ci| ctx.mod.cells[ci].name else g.sample.items[0];
    const what: []const u8 = if (g.cell != null) "endpoint" else "input port";
    const message = try std.fmt.allocPrint(ctx.alloc,
        "unresolved clock association on {s} '{s}': {s}; {d} crossings cannot prove synchronicity (sample: {s})",
        .{ what, key, why, g.count, sample });
    return .{ .rule = rule.id, .severity = rule.severity, .dst = dst, .message = message };
}
