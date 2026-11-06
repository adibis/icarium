const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "CDC-021",
    .severity = .err,
    .title = "Flop clock driven by an undeclared port",
    .doc =
    \\A top-level input port drives flop clocks with no create_clock
    \\behind it. Undeclared clocks appear in no async group, so every
    \\other check touching the domain silently skips. Declare it.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// One finding per undeclared clock port: every flop it drives
// lists as a consumer. Synthetic port domains are undeclared by
// construction; declared roots never take that shape.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var groups = std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)).empty;
    var dit = ctx.table.domains.iterator();
    while (dit.next()) |de| {
        const ci = de.key_ptr.*;
        if (clock.cells.isLatch(ctx.mod.cells[ci].type)) continue;
        if (!std.mem.startsWith(u8, de.value_ptr.name, "port:")) continue;
        const port = de.value_ptr.root;
        if (!isInputPort(ctx, port)) continue;
        const slot = try groups.getOrPut(ctx.tmp, port);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(ctx.tmp, ctx.mod.cells[ci].name);
    }
    var ports = std.ArrayListUnmanaged([]const u8).empty;
    var git = groups.iterator();
    while (git.next()) |ge| try ports.append(ctx.tmp, ge.key_ptr.*);
    std.mem.sort([]const u8, ports.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    for (ports.items) |p| {
        const consumers = groups.get(p).?;
        std.mem.sort([]const u8, consumers.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        const desc = try consumerDesc(ctx, consumers.items);
        const message = try std.fmt.allocPrint(ctx.tmp,
            "flop CLK driven by undeclared port: top-level input port '{s}' drives {s} but has no create_clock declaration in the SDC. All other CDC checks that touch this domain are silently skipped. Add `create_clock -name {s} -period <T> [get_ports {s}]` to the SDC.",
            .{ p, desc, p, p });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = consumers.items[0],
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

fn isInputPort(ctx: *context.Context, port: []const u8) bool {
    for (ctx.mod.ports) |p| {
        if (std.mem.eql(u8, p.name, port)) return p.direction == .input;
    }
    return false;
}

// One flop reads bare; crowds read as a count with a sample.
fn consumerDesc(ctx: *context.Context, names: [][]const u8) error{OutOfMemory}![]const u8 {
    if (names.len == 1) return std.fmt.allocPrint(ctx.tmp, "flop {s}", .{names[0]});
    var buf = std.ArrayListUnmanaged(u8).empty;
    const head = try std.fmt.allocPrint(ctx.tmp, "{d} flops (", .{names.len});
    try buf.appendSlice(ctx.tmp, head);
    const show = @min(names.len, 3);
    for (names[0..show], 0..) |n, i| {
        if (i > 0) try buf.appendSlice(ctx.tmp, ", ");
        try buf.appendSlice(ctx.tmp, n);
    }
    if (names.len > 3) try buf.appendSlice(ctx.tmp, ", ...");
    try buf.appendSlice(ctx.tmp, ")");
    return buf.toOwnedSlice(ctx.tmp);
}
