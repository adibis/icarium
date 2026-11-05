const std = @import("std");
const suppress = @import("icarium").suppress;

test "meridian parses continuations, braces, and expressions" {
    const text =
        \\# a comment line
        \\set_rule_status -rule {W_MASYNC} -status {Waived} \
        \\  -expression {(Driver =~ "u_top.u_a.*") && (ReceivingFlop =~ "u_top.u_b.sync0")} \
        \\  -comment {async path reviewed}
        \\source {more.tcl} ; # trailing comment
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try suppress.meridian.parseText(arena.allocator(), text);
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    const r = cmds[0].record;
    try std.testing.expectEqualStrings("W_MASYNC", r.rules[0]);
    try std.testing.expectEqualStrings("Waived", r.status);
    try std.testing.expectEqualStrings("u_top.u_a.*", r.driver.?);
    try std.testing.expectEqualStrings("u_top.u_b.sync0", r.receiver.?);
    try std.testing.expectEqualStrings("async path reviewed", r.comment);
    try std.testing.expectEqual(@as(u32, 2), r.line);
    try std.testing.expectEqualStrings("more.tcl", cmds[1].source.path);
}

test "meridian rejects unknown surface loudly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad = [_][]const u8{
        "set_foo -rule {X}\n",
        "set_rule_status -rule {X} -status {Waived} -bogus {Y}\n",
        "set_rule_status -rule {X} -status {Waived} -expression {(Clock =~ \"c\")}\n",
        "set_rule_status -rule {X} -status {Waived} -expression {(Driver ~~ \"d\")}\n",
        "set_rule_status -rule {X} -status {Waived} -expression unbraced\n",
        "set_rule_status -rule {} -status {Waived}\n",
        "set_rule_status -rule {X\n",
    };
    for (bad) |t| {
        try std.testing.expectError(error.BadTcl, suppress.meridian.parseText(arena.allocator(), t));
    }
}

test "meridian converts mapped rules and collects the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map = try suppress.meridian.loadMap(arena.allocator(), "{\"W_MASYNC\": [\"CDC-001\", \"CDC-004\"]}");
    const records = [_]suppress.meridian.Record{
        .{ .rules = @constCast(&[_][]const u8{"W_MASYNC"}), .status = "Waived", .driver = "u_a.*", .receiver = "u_b.s", .comment = "ok", .line = 1 },
        .{ .rules = @constCast(&[_][]const u8{"W_OTHER"}), .status = "Waived", .driver = null, .receiver = null, .comment = "new", .line = 2 },
        .{ .rules = @constCast(&[_][]const u8{"W_MASYNC"}), .status = "Review", .driver = null, .receiver = null, .comment = "not waived", .line = 3 },
    };
    const out = try suppress.meridian.convert(arena.allocator(), &records, &map);
    const items = out.waivers.object.get("waivers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    const w = items[0].object;
    try std.testing.expectEqualStrings("meridian-0001", w.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 2), w.get("rules").?.array.items.len);
    try std.testing.expectEqualStrings("u_b.s", w.get("dst").?.string);
    try std.testing.expectEqualStrings("u_a.*", w.get("driver").?.string);
    try std.testing.expectEqual(@as(usize, 1), out.unmapped.len);
    try std.testing.expectEqualStrings("W_OTHER", out.unmapped[0].rule);
    try std.testing.expectEqual(@as(u32, 2), out.unmapped[0].line);
    try std.testing.expectEqual(@as(u32, 1), out.skipped);
}

test "meridian map load rejects typos" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadMap, suppress.meridian.loadMap(arena.allocator(), "[]"));
    try std.testing.expectError(error.BadMap, suppress.meridian.loadMap(arena.allocator(), "{\"W_X\": []}"));
    try std.testing.expectError(error.BadMap, suppress.meridian.loadMap(arena.allocator(), "{\"W_X\": [\"CDC-777\"]}"));
}
