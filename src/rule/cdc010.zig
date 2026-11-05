const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");
const sdc = @import("../sdc.zig");

pub const rule = registry.Rule{
    .id = "CDC-010",
    .severity = .err,
    .title = "Glitch on the clock network from a wrong-domain control signal",
    .doc =
    \\A clock mux select or gate enable is driven from a domain
    \\async to every clock the cell gates: the transition chops the
    \\output clock into runt pulses no sink synchronizer can heal.
    \\Synchronize the control into one of the gated-clock domains.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// Each control pin's flop fanin must share a gated clock, or
// the async transition chops the output. Ports defer out.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    const mod = ctx.mod;
    const net_cells = try context.clockNetworkCells(ctx.alloc, mod);
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    for (mod.cells, 0..) |c, ci| {
        if (!net_cells.contains(ci)) continue;
        const ctrls = controlPins(ctx, c);
        if (ctrls.len == 0) continue;
        const gated = try clockInputDomains(ctx, ci, ctrls);
        if (gated.cells.items.len == 0 and gated.clocks.items.len == 0) continue;
        for (ctrls) |cp| {
            const bits = portBits(c, cp) orelse continue;
            if (bits.len == 0) continue;
            if (anyGlitchless(ctx, bits)) continue;
            const fanin = try flopFanin(ctx, bits);
            if (fanin.items.len == 0) continue;
            std.mem.sort(usize, fanin.items, {}, struct {
                fn less(_: void, a: usize, b: usize) bool {
                    return a < b;
                }
            }.less);
            var prev: ?usize = null;
            for (fanin.items) |src| {
                if (prev == src) continue;
                prev = src;
                const sdom = ctx.table.domainOf(src) orelse continue;
                if (std.mem.eql(u8, sdom.name, "unknown")) continue;
                if (!allAsync(ctx, sdom, gated)) continue;
                const doms = try describeDomains(ctx, gated);
                const message = try std.fmt.allocPrint(ctx.alloc,
                    "clock-network cell {s} ({s}) control pin {s} is driven by flop {s} in domain {s}, asynchronous to the cell's clock-input domain(s) ({s}); an async control transition can chop the output clock into runt pulses on every downstream flop. Synchronize {s} into one of the gated-clock domains",
                    .{ c.name, c.type, cp, mod.cells[src].name, sdom.name, doms, mod.cells[src].name });
                try out.append(ctx.alloc, .{
                    .rule = rule.id,
                    .severity = rule.severity,
                    .dst = c.name,
                    .message = message,
                });
            }
        }
    }
    return out.toOwnedSlice(ctx.alloc);
}

const explicit_controls = std.StaticStringMap([]const []const u8).initComptime(.{
    .{ "$mux", &.{"S"} },
    .{ "$dffe", &.{"EN"} },
    .{ "$dlatch", &.{"EN"} },
    .{ "$_MUX_", &.{"S"} },
    .{ "$_MUX4_", &.{ "S", "T" } },
    .{ "$_MUX8_", &.{ "S", "T", "U" } },
    .{ "$_MUX16_", &.{ "S", "T", "U", "V" } },
});

const heuristic_pins = std.StaticStringMap(void).initComptime(.{
    .{ "E", {} },
    .{ "EN", {} },
    .{ "CE", {} },
    .{ "GATE", {} },
    .{ "SE", {} },
});

// Explicit cell map, then gate-level prefixes, then pin-name
// guessing for library cells. Buffers fall through pinless.
fn controlPins(ctx: *context.Context, c: ir.types.Cell) []const []const u8 {
    if (explicit_controls.get(c.type)) |pins| return pins;
    if (std.mem.startsWith(u8, c.type, "$_DLATCH") or
        std.mem.startsWith(u8, c.type, "$_DFFE_") or
        std.mem.startsWith(u8, c.type, "$_SDFFE_")) return &.{"E"};
    if (!ctx.cfg.cdc010_heuristic) return &.{};
    var matches = std.ArrayListUnmanaged([]const u8).empty;
    for (c.ports) |p| {
        if (p.direction == .output or p.bits.len == 0) continue;
        var upper: [16]u8 = undefined;
        if (p.name.len > upper.len) continue;
        for (p.name, 0..) |ch, i| upper[i] = std.ascii.toUpper(ch);
        if (heuristic_pins.get(upper[0..p.name.len]) != null) {
            matches.append(ctx.alloc, p.name) catch return &.{};
        }
    }
    return matches.items;
}

const GatedDomains = struct {
    cells: std.ArrayListUnmanaged(usize),
    clocks: std.ArrayListUnmanaged([]const u8),
};

// Clock sources behind non-control inputs: flop cells plus SDC
// clock ports. Nothing classifiable means silence, not a guess.
fn clockInputDomains(
    ctx: *context.Context,
    ci: usize,
    ctrls: []const []const u8,
) error{OutOfMemory}!GatedDomains {
    const mod = ctx.mod;
    var cells = std.ArrayListUnmanaged(usize).empty;
    var clocks = std.ArrayListUnmanaged([]const u8).empty;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(FrontierBit).empty;
    for (mod.cells[ci].ports) |p| {
        if (p.direction == .output) continue;
        if (isCtrl(p.name, ctrls)) continue;
        for (p.bits) |b| {
            if (b == .sig) try frontier.append(ctx.alloc, .{ .bit = b.sig, .depth = 0 });
        }
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const fb = frontier.items[head];
        if (seen.contains(fb.bit)) continue;
        try seen.put(ctx.alloc, fb.bit, {});
        const drv = mod.driver_of.get(fb.bit) orelse {
            if (portOfBit(mod, fb.bit)) |pn| {
                if (sdc.model.rootClock(ctx.model, pn)) |clk| try clocks.append(ctx.alloc, clk);
            }
            continue;
        };
        const sci = drv.cell orelse {
            if (portOfBit(mod, fb.bit)) |pn| {
                if (sdc.model.rootClock(ctx.model, pn)) |clk| try clocks.append(ctx.alloc, clk);
            }
            continue;
        };
        if (std.mem.eql(u8, drv.port, "Q")) {
            try cells.append(ctx.alloc, sci);
            continue;
        }
        if (fb.depth >= 12) continue;
        for (mod.cells[sci].ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b == .sig) try frontier.append(ctx.alloc, .{ .bit = b.sig, .depth = fb.depth + 1 });
            }
        }
    }
    return .{ .cells = cells, .clocks = clocks };
}

fn isCtrl(name: []const u8, ctrls: []const []const u8) bool {
    for (ctrls) |c| {
        if (std.mem.eql(u8, c, name)) return true;
    }
    return false;
}

// Flop cells whose Q feeds the control bits through combinational
// logic. Ports and constants end the walk with no answer.
fn flopFanin(ctx: *context.Context, start: []ir.bits.Bit) error{OutOfMemory}!std.ArrayListUnmanaged(usize) {
    const mod = ctx.mod;
    var flops = std.ArrayListUnmanaged(usize).empty;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(FrontierBit).empty;
    for (start) |b| {
        if (b == .sig) try frontier.append(ctx.alloc, .{ .bit = b.sig, .depth = 0 });
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const fb = frontier.items[head];
        if (seen.contains(fb.bit)) continue;
        try seen.put(ctx.alloc, fb.bit, {});
        const drv = mod.driver_of.get(fb.bit) orelse continue;
        const sci = drv.cell orelse continue;
        if (std.mem.eql(u8, drv.port, "Q")) {
            try flops.append(ctx.alloc, sci);
            continue;
        }
        if (fb.depth >= 12) continue;
        for (mod.cells[sci].ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b == .sig) try frontier.append(ctx.alloc, .{ .bit = b.sig, .depth = fb.depth + 1 });
            }
        }
    }
    return flops;
}

// Async to every gated clock on every leg: one synchronous pair
// anywhere proves the control shares a clock and stays silent.
fn allAsync(ctx: *context.Context, sdom: clock.trace.Domain, gated: GatedDomains) bool {
    if (sdom.legs.len == 0) return false;
    for (sdom.legs) |sl| {
        for (gated.cells.items) |gc| {
            const gdom = ctx.table.domainOf(gc) orelse continue;
            for (gdom.legs) |gl| {
                if (!ctx.model.areAsync(sl, gl)) return false;
            }
        }
        for (gated.clocks.items) |gc| {
            if (!ctx.model.areAsync(sl, gc)) return false;
        }
    }
    return true;
}

fn anyGlitchless(ctx: *context.Context, bits: []ir.bits.Bit) bool {
    for (bits) |b| {
        if (b == .sig and ctx.marks.glitchlessBit(b.sig)) return true;
    }
    return false;
}

fn describeDomains(ctx: *context.Context, gated: GatedDomains) error{OutOfMemory}![]const u8 {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    const add = struct {
        fn f(list: *std.ArrayListUnmanaged([]const u8), alloc: std.mem.Allocator, n: []const u8) error{OutOfMemory}!void {
            for (list.items) |o| {
                if (std.mem.eql(u8, o, n)) return;
            }
            try list.append(alloc, n);
        }
    }.f;
    for (gated.cells.items) |gc| {
        if (ctx.table.domainOf(gc)) |d| try add(&names, ctx.alloc, d.name);
    }
    for (gated.clocks.items) |c| try add(&names, ctx.alloc, c);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return std.mem.join(ctx.alloc, ", ", names.items);
}

const FrontierBit = struct { bit: u32, depth: u8 };

fn portOfBit(mod: *const ir.types.Module, bit: u32) ?[]const u8 {
    for (mod.ports) |p| {
        for (p.bits) |b| {
            if (b == .sig and b.sig == bit) return p.name;
        }
    }
    return null;
}

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
    }
    return null;
}
