// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const elab = @import("icarium").cli_elaborate;

test "script reads, picks the top and keeps RTL structure" {
    const s = try elab.script(std.testing.allocator, .{
        .top = "t",
        .includes = &.{"inc"},
        .defines = &.{ "W=4", "SIM" },
        .files = &.{ "a.sv", "dir with space/b.sv" },
    });
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings(
        "read_verilog -sv -I inc -D W=4 -D SIM \"a.sv\" \"dir with space/b.sv\"; " ++
            "hierarchy -check -top t; proc; flatten; write_json",
        s,
    );
}

test "without a top, Yosys picks one; slang gets it too when given" {
    const a = try elab.script(std.testing.allocator, .{ .files = &.{"a.sv"} });
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("read_verilog -sv \"a.sv\"; hierarchy -check -auto-top; proc; flatten; write_json", a);
    const b = try elab.script(std.testing.allocator, .{ .top = "t", .frontend = .slang, .files = &.{"a.sv"} });
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("read_slang --top t a.sv; hierarchy -check -top t; proc; flatten; write_json", b);
}

test "arguments Yosys would misread are refused" {
    try std.testing.expect(elab.validate(.{ .files = &.{"dir with space/a.sv"} }) == null);
    const cases = [_]struct { o: elab.Options, what: []const u8 }{
        .{ .o = .{ .files = &.{"a.sv; shell b"} }, .what = "source file" },
        .{ .o = .{ .files = &.{"a\".sv"} }, .what = "source file" },
        .{ .o = .{ .files = &.{"#a.sv"} }, .what = "source file" },
        .{ .o = .{ .files = &.{""} }, .what = "source file" },
        .{ .o = .{ .files = &.{"a.sv"}, .includes = &.{"inc dir"} }, .what = "include directory" },
        .{ .o = .{ .files = &.{"a.sv"}, .defines = &.{"MSG=\"hi\""} }, .what = "define" },
        .{ .o = .{ .files = &.{"a.sv"}, .top = "t\n" }, .what = "top" },
        .{ .o = .{ .frontend = .slang, .files = &.{"dir with space/a.sv"} }, .what = "source file" },
    };
    for (cases) |c| {
        const bad = elab.validate(c.o) orelse return error.TestExpectedRefusal;
        try std.testing.expectEqualStrings(c.what, bad.what);
    }
}
