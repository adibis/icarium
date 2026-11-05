const std = @import("std");
const rule = @import("../rule.zig");

pub fn run(init: std.process.Init, out: anytype, err: anytype, argv: []const []const u8) u8 {
    _ = init;
    if (argv.len == 0) {
        err.writeAll("rules: want --list or --doc\n") catch {};
        return 2;
    }
    if (std.mem.eql(u8, argv[0], "--list") and argv.len == 1) {
        rule.registry.renderList(out) catch return 3;
        return 0;
    }
    if (std.mem.eql(u8, argv[0], "--doc") and argv.len == 1) {
        rule.registry.renderDoc(out) catch return 3;
        return 0;
    }
    err.print("rules: bad argument: {s}\n", .{argv[0]}) catch {};
    return 2;
}
