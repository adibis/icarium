// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const path = @import("icarium").ir.path;

fn freePath(segs: [][]const u8) void {
    for (segs) |s| std.testing.allocator.free(s);
    std.testing.allocator.free(segs);
}

test "flat name has empty path" {
    const p = try path.splitInstancePath(std.testing.allocator, "$mux$1");
    defer freePath(p);
    try std.testing.expectEqual(@as(usize, 0), p.len);
}

test "dotted name splits, leaf dropped" {
    const p = try path.splitInstancePath(std.testing.allocator, "u_spi.u_mem.$rd1");
    defer freePath(p);
    try std.testing.expectEqual(@as(usize, 2), p.len);
    try std.testing.expectEqualStrings("u_spi", p[0]);
    try std.testing.expectEqualStrings("u_mem", p[1]);
}

test "escaped dots stay literal" {
    const p = try path.splitInstancePath(std.testing.allocator, "top.weird\\.name.$c");
    defer freePath(p);
    try std.testing.expectEqual(@as(usize, 2), p.len);
    try std.testing.expectEqualStrings("top", p[0]);
    try std.testing.expectEqualStrings("weird.name", p[1]);
}
