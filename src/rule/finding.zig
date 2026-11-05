const std = @import("std");
const registry = @import("registry.zig");

// One rule verdict on one crossing: owned message, borrowed
// names. Findings order by (rule, dst, message) for reruns.
// Driver stays null where the rule cannot name one; reporters
// render the receiver side alone rather than guess.
pub const Finding = struct {
    rule: []const u8,
    severity: registry.Severity,
    dst: []const u8,
    driver: ?[]const u8 = null,
    message: []const u8,

    pub fn less(_: void, a: Finding, b: Finding) bool {
        const r = std.mem.order(u8, a.rule, b.rule);
        if (r != .eq) return r == .lt;
        const d = std.mem.order(u8, a.dst, b.dst);
        if (d != .eq) return d == .lt;
        return std.mem.order(u8, a.message, b.message) == .lt;
    }
};

pub fn renderId(out: anytype, f: Finding) !void {
    try out.print("{s}\n", .{f.rule});
}
