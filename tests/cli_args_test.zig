// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const args = @import("icarium").cli_args;

test "help spellings parse" {
    try std.testing.expectEqual(args.Command.help, args.parse("help").?);
    try std.testing.expectEqual(args.Command.help, args.parse("--help").?);
    try std.testing.expectEqual(args.Command.help, args.parse("-h").?);
}

test "version spellings parse" {
    try std.testing.expectEqual(args.Command.version, args.parse("version").?);
    try std.testing.expectEqual(args.Command.version, args.parse("--version").?);
    try std.testing.expectEqual(args.Command.version, args.parse("-V").?);
}

test "subcommands parse" {
    try std.testing.expectEqual(args.Command.stats, args.parse("stats").?);
    try std.testing.expectEqual(args.Command.clocks, args.parse("clocks").?);
    try std.testing.expectEqual(args.Command.domains, args.parse("domains").?);
    try std.testing.expectEqual(args.Command.resets, args.parse("resets").?);
    try std.testing.expectEqual(args.Command.crossings, args.parse("crossings").?);
}

test "near misses parse to null" {
    try std.testing.expectEqual(@as(?args.Command, null), args.parse("helps"));
    try std.testing.expectEqual(@as(?args.Command, null), args.parse(""));
    try std.testing.expectEqual(@as(?args.Command, null), args.parse("versions"));
    try std.testing.expectEqual(@as(?args.Command, null), args.parse("--verb"));
}
