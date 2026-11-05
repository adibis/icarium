const std = @import("std");

pub const Command = enum { help, version, stats, clocks, domains, resets };

// Fixed vocabulary, resolved once at compile time: adding a
// command is one table row, and typos fail closed to null.
const table = std.StaticStringMap(Command).initComptime(.{
    .{ "help", .help },
    .{ "--help", .help },
    .{ "-h", .help },
    .{ "version", .version },
    .{ "--version", .version },
    .{ "-V", .version },
    .{ "stats", .stats },
    .{ "clocks", .clocks },
    .{ "domains", .domains },
    .{ "resets", .resets },
});

pub fn parse(s: []const u8) ?Command {
    return table.get(s);
}
