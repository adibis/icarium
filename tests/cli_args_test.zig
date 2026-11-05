const std = @import("std");
const args = @import("icarium").cli_args;

test "help spellings match" {
    try std.testing.expect(args.isHelp("help"));
    try std.testing.expect(args.isHelp("--help"));
    try std.testing.expect(args.isHelp("-h"));
}

test "version spellings match" {
    try std.testing.expect(args.isVersion("version"));
    try std.testing.expect(args.isVersion("--version"));
    try std.testing.expect(args.isVersion("-V"));
}

test "near misses do not match" {
    try std.testing.expect(!args.isHelp("helps"));
    try std.testing.expect(!args.isHelp(""));
    try std.testing.expect(!args.isVersion("versions"));
    try std.testing.expect(!args.isVersion("--verb"));
}
