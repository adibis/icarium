const std = @import("std");

pub fn isHelp(s: []const u8) bool {
    return std.mem.eql(u8, s, "help") or std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "-h");
}

pub fn isVersion(s: []const u8) bool {
    return std.mem.eql(u8, s, "version") or std.mem.eql(u8, s, "--version") or std.mem.eql(u8, s, "-V");
}
