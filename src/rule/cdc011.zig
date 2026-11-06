const std = @import("std");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-011",
    .severity = .warn,
    .title = "Unconstrained primary input captured by clocked logic",
    .doc =
    \\A top input with no set_input_delay clock typing reaches a
    \\flop D or SRST pin: one domain is a methodology warning, two
    \\or more an error no typing can silence. Type the port, then
    \\synchronize the foreign side when the domains disagree.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// Untyped-port captures gather by port; each port fires once,
// escalating when its destinations span clock domains.
pub const Accum = struct {
    by_port: std.StringHashMapUnmanaged(PortDsts) = .empty,
};

pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var acc = Accum{};
    for (ctx.crossings) |x| try accumulate(&acc, ctx, x);
    return finish(&acc, ctx);
}

pub fn accumulate(acc: *Accum, ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!void {
    if (x.kind != .port_flop_untyped) return;
    if (!std.mem.eql(u8, x.dst.port, "D") and !std.mem.eql(u8, x.dst.port, "SRST")) return;
    if (std.mem.eql(u8, x.dst_clk, "unknown")) return;
    const dc = x.dst.cell orelse return;
    const slot = try acc.by_port.getOrPut(ctx.alloc, x.src.port);
    // Port keys copy out on insert: probes borrow the crossing,
    // but the accumulator outlives the batch.
    if (!slot.found_existing) {
        slot.key_ptr.* = try ctx.alloc.dupe(u8, x.src.port);
        slot.value_ptr.* = .{};
    }
    try slot.value_ptr.add(ctx.alloc, x.dst_clk, ctx.mod.cells[dc].name);
}

pub fn finish(acc: *Accum, ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var ports = std.ArrayListUnmanaged([]const u8).empty;
    var it = acc.by_port.iterator();
    while (it.next()) |e| try ports.append(ctx.tmp, e.key_ptr.*);
    std.mem.sort([]const u8, ports.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    for (ports.items) |port| {
        const dsts = acc.by_port.get(port).?;
        try out.append(ctx.tmp, try fire(ctx, port, dsts));
    }
    return out.toOwnedSlice(ctx.tmp);
}

const PortDsts = struct {
    clocks: std.StringHashMapUnmanaged(void) = .empty,
    best: ?[]const u8 = null,

    // Distinct clocks plus the smallest cell: finish prints the
    // clock set and names one representative, so the per-pair
    // lists this replaces kept nothing the verdict can read.
    fn add(self: *PortDsts, alloc: std.mem.Allocator, clk: []const u8, cell: []const u8) error{OutOfMemory}!void {
        const slot = try self.clocks.getOrPut(alloc, clk);
        // Clocks copy out on insert: batch crossings die young.
        if (!slot.found_existing) slot.key_ptr.* = try alloc.dupe(u8, clk);
        if (self.best == null or std.mem.lessThan(u8, cell, self.best.?)) self.best = cell;
    }

    fn distinctClocks(self: *const PortDsts, alloc: std.mem.Allocator) error{OutOfMemory}![][]const u8 {
        var out = std.ArrayListUnmanaged([]const u8).empty;
        var it = self.clocks.iterator();
        while (it.next()) |e| try out.append(alloc, e.key_ptr.*);
        std.mem.sort([]const u8, out.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        return out.toOwnedSlice(alloc);
    }

    fn reprCell(self: *const PortDsts) []const u8 {
        return self.best.?;
    }
};

fn fire(ctx: *context.Context, port: []const u8, dsts: PortDsts) error{OutOfMemory}!finding.Finding {
    const clocks = try dsts.distinctClocks(ctx.tmp);
    const repr = dsts.reprCell();
    if (clocks.len > 1) {
        const joined = try std.mem.join(ctx.tmp, ", ", clocks);
        const message = try std.fmt.allocPrint(ctx.tmp, "unconstrained primary input '{s}' is captured in multiple clock domains ({s}); a single port cannot be synchronous to more than one clock \xe2\x80\x94 add set_input_delay -clock <name> and a synchronizer on at least one destination", .{ port, joined });
        return .{ .rule = rule.id, .severity = .err, .dst = repr, .message = message };
    }
    const message = try std.fmt.allocPrint(ctx.tmp, "unconstrained primary input '{s}' has no set_input_delay -clock typing in the SDC but is captured in domain '{s}'; add set_input_delay -clock {s} [get_ports {s}] (or declare the port's true source clock and add a synchronizer)", .{ port, clocks[0], clocks[0], port });
    return .{ .rule = rule.id, .severity = .warn, .dst = repr, .message = message };
}
