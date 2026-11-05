const std = @import("std");
const registry = @import("registry.zig");

// One rule verdict on one crossing: owned message, borrowed
// names. Findings order by (rule, dst, message) for reruns.
pub const Finding = struct {
    rule: []const u8,
    severity: registry.Severity,
    dst: []const u8,
    message: []const u8,

    pub fn less(_: void, a: Finding, b: Finding) bool {
        const r = std.mem.order(u8, a.rule, b.rule);
        if (r != .eq) return r == .lt;
        const d = std.mem.order(u8, a.dst, b.dst);
        if (d != .eq) return d == .lt;
        return std.mem.order(u8, a.message, b.message) == .lt;
    }
};

pub fn renderText(out: anytype, f: Finding) !void {
    try out.print("{s} [{t}] {s}: {s}\n", .{ f.rule, f.severity, f.dst, f.message });
}

pub fn renderId(out: anytype, f: Finding) !void {
    try out.print("{s}\n", .{f.rule});
}
