// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const registry = @import("registry.zig");

// One rule verdict on one crossing: owned message, borrowed
// names. Findings order by (rule, dst, driver, message) for reruns.
// Driver stays null where the rule cannot name one; reporters
// render the receiver side alone rather than guess. The waiver
// hit arrives post-check from the suppression layer; rules
// never excuse their own findings.
pub const WaiverHit = struct {
    id: []const u8,
    reason: []const u8,
    location: ?[]const u8,
};

pub const Finding = struct {
    rule: []const u8,
    severity: registry.Severity,
    dst: []const u8,
    driver: ?[]const u8 = null,
    waiver: ?WaiverHit = null,
    message: []const u8,

    pub fn less(_: void, a: Finding, b: Finding) bool {
        const r = std.mem.order(u8, a.rule, b.rule);
        if (r != .eq) return r == .lt;
        const d = std.mem.order(u8, a.dst, b.dst);
        if (d != .eq) return d == .lt;
        const da = a.driver orelse "";
        const db = b.driver orelse "";
        const v = std.mem.order(u8, da, db);
        if (v != .eq) return v == .lt;
        return std.mem.order(u8, a.message, b.message) == .lt;
    }
};

pub fn renderId(out: anytype, f: Finding) !void {
    try out.print("{s}\n", .{f.rule});
}
