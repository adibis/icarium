const std = @import("std");
const tokens = @import("icarium").sdc.tokens;

fn parseWithArena(arena: *std.heap.ArenaAllocator, text: []const u8) !struct {
    cmds: []tokens.Command,
    warnings: []tokens.Warning,
} {
    var warns: std.ArrayListUnmanaged(tokens.Warning) = .empty;
    const cmds = try tokens.parseCommands(arena.allocator(), text, &warns);
    return .{ .cmds = cmds, .warnings = try warns.toOwnedSlice(arena.allocator()) };
}

test "continuations join, comments strip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseWithArena(&arena,
        \\# full-line comment
        \\create_clock -name clk \
        \\  -period 10 [get_ports clk] # trailing comment
    );
    try std.testing.expectEqual(@as(usize, 1), r.cmds.len);
    try std.testing.expectEqual(@as(usize, 2), r.cmds[0].line);
    const w = r.cmds[0].words;
    try std.testing.expectEqual(@as(usize, 6), w.len);
    try std.testing.expectEqualStrings("create_clock", w[0]);
    try std.testing.expectEqualStrings("clk", w[5]);
}

test "braces group, semicolons split" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseWithArena(&arena, "set_clock_groups -async -group {a b}; set_false_path -from x -to y");
    try std.testing.expectEqual(@as(usize, 2), r.cmds.len);
    try std.testing.expectEqualStrings("-group", r.cmds[0].words[2]);
    try std.testing.expectEqualStrings("a b", r.cmds[0].words[3]);
    try std.testing.expectEqualStrings("set_false_path", r.cmds[1].words[0]);
}

test "nested braces strip one level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseWithArena(&arena, "cmd {a {b} c}");
    try std.testing.expectEqualStrings("a {b} c", r.cmds[0].words[1]);
}

test "quotes group with escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseWithArena(&arena, "cmd \"a\\\"b\" plain");
    try std.testing.expectEqualStrings("a\"b", r.cmds[0].words[1]);
    try std.testing.expectEqualStrings("plain", r.cmds[0].words[2]);
}

test "hash inside word stays literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseWithArena(&arena, "cmd foo#bar");
    try std.testing.expectEqualStrings("foo#bar", r.cmds[0].words[1]);
}

test "forbidden substitution refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var warns: std.ArrayListUnmanaged(tokens.Warning) = .empty;
    const e1 = tokens.parseCommands(arena.allocator(), "cmd [exec rm]", &warns);
    try std.testing.expectError(error.ForbiddenSubstitution, e1);
    const e2 = tokens.parseCommands(arena.allocator(), "cmd [get_ports [get_cells x]]", &warns);
    try std.testing.expectError(error.NestedSubstitution, e2);
    const e3 = tokens.parseCommands(arena.allocator(), "cmd pre[get_ports x]", &warns);
    try std.testing.expectError(error.GluedSubstitution, e3);
}

test "get_nets splices like other readers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseWithArena(&arena, "create_clock -name c [get_nets clk_net]");
    try std.testing.expectEqualStrings("clk_net", r.cmds[0].words[3]);
}

test "bus bit-selects splice, nested commands still refuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseWithArena(&arena, "set_input_delay -clock c [get_ports bus[*]]");
    try std.testing.expectEqualStrings("bus", r.cmds[0].words[3]);
    var warns: std.ArrayListUnmanaged(tokens.Warning) = .empty;
    const e = tokens.parseCommands(arena.allocator(), "cmd [get_ports [get_cells x]]", &warns);
    try std.testing.expectError(error.NestedSubstitution, e);
}

test "unbalanced grouping fails loud" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var warns: std.ArrayListUnmanaged(tokens.Warning) = .empty;
    try std.testing.expectError(error.UnbalancedBraces, tokens.parseCommands(arena.allocator(), "cmd {a b", &warns));
    try std.testing.expectError(error.UnbalancedQuote, tokens.parseCommands(arena.allocator(), "cmd \"ab", &warns));
    try std.testing.expectError(error.UnbalancedBracket, tokens.parseCommands(arena.allocator(), "cmd [get_ports x", &warns));
}
