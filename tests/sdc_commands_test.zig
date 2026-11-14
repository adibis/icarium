// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const sdc = @import("icarium").sdc;

fn parseOne(arena: *std.heap.ArenaAllocator, text: []const u8) !struct {
    parsed: sdc.commands.Parsed,
    warnings: []sdc.tokens.Warning,
} {
    var warns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    const cmds = try sdc.tokens.parseCommands(arena.allocator(), text, &warns);
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    const p = try sdc.commands.parse(arena.allocator(), cmds[0], &warns);
    return .{ .parsed = p, .warnings = try warns.toOwnedSlice(arena.allocator()) };
}

test "create_clock fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseOne(&arena, "create_clock -name clk -period 10.5 [get_ports {clk rst}]");
    const c = r.parsed.create_clock;
    try std.testing.expectEqualStrings("clk", c.name);
    try std.testing.expectEqual(@as(f64, 10.5), c.period.?);
    try std.testing.expectEqual(@as(usize, 2), c.objects.len);
    try std.testing.expectEqual(@as(usize, 0), r.warnings.len);
}

test "create_clock without name skips with warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseOne(&arena, "create_clock -period 10 p");
    try std.testing.expect(r.parsed == .skipped);
    try std.testing.expectEqual(@as(usize, 1), r.warnings.len);
}

test "generated clock ratios" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseOne(&arena, "create_generated_clock -name d2 -source clk -divide_by 2 [get_pins u_div/q]");
    const c = r.parsed.generated_clock;
    try std.testing.expectEqualStrings("d2", c.name);
    try std.testing.expectEqualStrings("clk", c.master);
    try std.testing.expectEqual(@as(u32, 2), c.divide_by);
    try std.testing.expectEqual(@as(u32, 1), c.multiply_by);
}

test "combinational generated clock reads as div-by-1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseOne(&arena, "create_generated_clock -name muxo -source clk -combinational [get_pins u_mux/y]");
    const c = r.parsed.generated_clock;
    try std.testing.expectEqualStrings("muxo", c.name);
    try std.testing.expectEqual(@as(u32, 1), c.divide_by);
    try std.testing.expectEqual(@as(usize, 0), r.warnings.len);
}

test "clock groups keep sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseOne(&arena, "set_clock_groups -asynchronous -group {a b} -group {c}");
    const g = r.parsed.clock_groups;
    try std.testing.expect(g.kind == .async);
    try std.testing.expectEqual(@as(usize, 2), g.groups.len);
    try std.testing.expectEqualStrings("a", g.groups[0][0]);
    try std.testing.expectEqualStrings("c", g.groups[1][0]);
}

test "false path endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseOne(&arena, "set_false_path -from {a b} -to c -setup");
    const f = r.parsed.false_path;
    try std.testing.expectEqual(@as(usize, 2), f.from.len);
    try std.testing.expectEqualStrings("c", f.to[0]);
    try std.testing.expectEqual(@as(usize, 1), r.warnings.len);
}

test "pin delays skip leading value, need clock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseOne(&arena, "set_input_delay 2.0 -clock clk -add_delay 0.5 [get_ports d]");
    const d = r.parsed.input_delay;
    try std.testing.expectEqualStrings("clk", d.clock);
    try std.testing.expectEqual(@as(usize, 1), d.objects.len);
    try std.testing.expectEqualStrings("d", d.objects[0]);

    const r2 = try parseOne(&arena, "set_output_delay 1.0 [get_ports q]");
    try std.testing.expect(r2.parsed == .skipped);
}

test "forbidden commands abort, unknown warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var warns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    const cmds = try sdc.tokens.parseCommands(arena.allocator(), "source other.tcl", &warns);
    try std.testing.expectError(error.ForbiddenCommand, sdc.commands.parse(arena.allocator(), cmds[0], &warns));

    const r = try parseOne(&arena, "set_voltage 1.1");
    try std.testing.expect(r.parsed == .unsupported);
    try std.testing.expectEqual(@as(usize, 1), r.warnings.len);
}
