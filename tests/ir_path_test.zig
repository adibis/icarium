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

test "flatten prefix and escape marks are not part of the path" {
    const p = try path.splitInstancePath(std.testing.allocator, "$flatten\\u_mid.\\u_leaf.$procdff$9");
    defer freePath(p);
    try std.testing.expectEqual(@as(usize, 2), p.len);
    try std.testing.expectEqualStrings("u_mid", p[0]);
    try std.testing.expectEqualStrings("u_leaf", p[1]);
}

test "a source path inside a generated name does not split" {
    const top = try path.splitInstancePath(std.testing.allocator, "$xor$rtl/top.sv:39$8");
    defer freePath(top);
    try std.testing.expectEqual(@as(usize, 0), top.len);
    const sub = try path.splitInstancePath(std.testing.allocator, "$flatten\\u_a.$and$rtl/a.sv:3$5");
    defer freePath(sub);
    try std.testing.expectEqual(@as(usize, 1), sub.len);
    try std.testing.expectEqualStrings("u_a", sub[0]);
}
