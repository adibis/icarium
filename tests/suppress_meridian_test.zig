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
    const cmds = try suppress.meridian.parseText(arena.allocator(), text, null);
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
        "set_rule_status -rule {X} -status {Waived} -expression {(Driver ~~ \"d\")}\n",
        "set_rule_status -rule {X} -status {Waived} -expression {(Driver =~ d)}\n",
        "set_rule_status -rule {X} -status {Waived} -expression {(Driver == \"d\"}\n",
        "set_rule_status -rule {X} -status {Waived} -expression {(Driver =~ \"d\") &&}\n",
        "set_rule_status -rule {X} -status {Waived} -expression unbraced\n",
        "set_rule_status -rule {} -status {Waived}\n",
        "set_rule_status -rule {X\n",
    };
    for (bad) |t| {
        var diag = suppress.meridian.Diagnostic{};
        const err = suppress.meridian.parseText(arena.allocator(), t, &diag);
        try std.testing.expectError(error.BadTcl, err);
        try std.testing.expect(diag.reason.len > 0);
    }
}

test "meridian reads value fields as context and locators as endpoints" {
    // Shapes mirror OpenTitan's waiver files (Apache-2.0, lowRISC).
    const text =
        "set_rule_status -rule {W_MASYNC} -status {waived} -expression {(ReceivingFlop =~ \"top.u_b.*\") && (MultiClockDomains == \"A::B\")} -comment {reviewed}\n" ++
        "set_rule_status -rule {RST_SYNC} -status { Waived } -expression {(ReceivingFlop =~ \\\"top.*.u_sync_1.q_o*\\\") && (ResetSignal == \\\"IO*\\\")} -comment {reset source}\n" ++
        "set_rule_status -rule {W_DATA} -status {Waived} -expression {(Signal=~\"top.u_spi*.q*\") && (ReceivingFlop=~\"top.u_pinmux.dio*\")} -comment {both ends}\n" ++
        "set_rule_status -rule {S_GENCLK} -status {Waived} -comment {rule-wide}\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try suppress.meridian.parseText(arena.allocator(), text, null);
    try std.testing.expectEqual(@as(usize, 4), cmds.len);
    const first = cmds[0].record;
    try std.testing.expectEqualStrings("waived", first.status);
    try std.testing.expect(first.driver == null);
    try std.testing.expectEqualStrings("top.u_b.*", first.receiver.?);
    try std.testing.expect(std.mem.indexOf(u8, first.comment, "MultiClockDomains=\"A::B\"") != null);
    const second = cmds[1].record;
    try std.testing.expectEqualStrings("top.*.u_sync_1.q_o*", second.receiver.?);
    try std.testing.expectEqualStrings("IO*", second.driver.?);
    const third = cmds[2].record;
    try std.testing.expectEqualStrings("top.u_spi*.q*", third.driver.?);
    try std.testing.expectEqualStrings("top.u_pinmux.dio*", third.receiver.?);
    const wide = cmds[3].record;
    try std.testing.expect(wide.driver == null);
    try std.testing.expect(wide.receiver == null);
}

test "meridian distributes disjunctions into sibling records" {
    const text =
        "set_rule_status -rule {W_CNTL} -status {Waived} -expression {((Signal=~\"*a*\") || (Signal=~\"*b*\")) && (ReceivingFlop=~\"*sync*\")} -comment {alt}\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try suppress.meridian.parseText(arena.allocator(), text, null);
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqualStrings("*a*", cmds[0].record.driver.?);
    try std.testing.expectEqualStrings("*sync*", cmds[0].record.receiver.?);
    try std.testing.expectEqualStrings("*b*", cmds[1].record.driver.?);
    try std.testing.expectEqualStrings("*sync*", cmds[1].record.receiver.?);
}

test "meridian joins entries across blank lines and skips audit stamps" {
    const text =
        "set_rule_status -rule {W_DATA} -status {Waived} -expression \\\n" ++
        "  {(Signal=~\"a*\") && \\\n" ++
        "\n" ++
        "  (ReceivingFlop =~ \"b*\")} -comment {wide} -lastedit_user {root} -lastedit_time {never}\n" ++
        "set_rule_status -rule {W_FANOUT} -expression {Driver =~ \"*c*\"} -status {Waived} -comment {bare}\n" ++
        "set_rule_status -rule {W_DATA} -expression {(Signal =~ \"d*\")} -comment {status-less}\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try suppress.meridian.parseText(arena.allocator(), text, null);
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    try std.testing.expectEqualStrings("a*", cmds[0].record.driver.?);
    try std.testing.expectEqualStrings("b*", cmds[0].record.receiver.?);
    try std.testing.expectEqualStrings("*c*", cmds[1].record.driver.?);
    try std.testing.expectEqualStrings("Waived", cmds[2].record.status);
    try std.testing.expect(std.mem.indexOf(u8, cmds[2].record.comment, "[no -status given]") != null);
}

test "meridian promotes sample and glitch endpoints to slots" {
    const text =
        "set_rule_status -rule {MULTCLK_CROSSINGS} -status {Waived} -expression {(SampleTxSignal == \"tx\") && (SampleRxSignal == \"rx\")} -comment {s}\n" ++
        "set_rule_status -rule {W_GLITCH} -status {Waived} -expression {(GlitchInput =~ \"gi\") && (GlitchOutput =~ \"go\")} -comment {g}\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try suppress.meridian.parseText(arena.allocator(), text, null);
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqualStrings("tx", cmds[0].record.driver.?);
    try std.testing.expectEqualStrings("rx", cmds[0].record.receiver.?);
    try std.testing.expectEqualStrings("gi", cmds[1].record.driver.?);
    try std.testing.expectEqualStrings("go", cmds[1].record.receiver.?);
}

test "meridian reads DrivingSignal as the driver" {
    const text =
        "set_rule_status -rule {W_ASYNC_RST_FLOPS} -status {Waived} -expression {(DrivingSignal=~\"IO*\") && (ReceivingFlop=~\"*u_spi_tpm.*\")} -comment {pad}\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try suppress.meridian.parseText(arena.allocator(), text, null);
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expectEqualStrings("IO*", cmds[0].record.driver.?);
    try std.testing.expectEqualStrings("*u_spi_tpm.*", cmds[0].record.receiver.?);
}

test "meridian splits crowded locator sides per locator" {
    const text =
        "set_rule_status -rule {W_MASYNC} -status {Waived} -expression {(ReceivingFlop =~ \"r1\") && (SyncFlop == \"r2\")} -comment {two receivers}\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try suppress.meridian.parseText(arena.allocator(), text, null);
    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqualStrings("r1", cmds[0].record.receiver.?);
    try std.testing.expect(cmds[0].record.driver == null);
    try std.testing.expectEqualStrings("r2", cmds[1].record.receiver.?);
    try std.testing.expect(cmds[1].record.driver == null);
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
