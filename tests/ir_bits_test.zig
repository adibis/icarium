// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const bits = @import("icarium").ir.bits;

test "signal bits round-trip" {
    const b = try bits.fromJson(.{ .integer = 42 });
    try std.testing.expectEqual(@as(u32, 42), b.sig);
}

test "constant spellings normalize" {
    try std.testing.expect((try bits.fromJson(.{ .string = "0" })) == .zero);
    try std.testing.expect((try bits.fromJson(.{ .string = "1" })) == .one);
    try std.testing.expect((try bits.fromJson(.{ .string = "x" })) == .x);
    try std.testing.expect((try bits.fromJson(.{ .string = "z" })) == .z);
}

test "negative and foreign values rejected" {
    try std.testing.expectError(error.NegativeBit, bits.fromJson(.{ .integer = -1 }));
    try std.testing.expectError(error.BadBits, bits.fromJson(.{ .string = "q" }));
    try std.testing.expectError(error.BadBits, bits.fromJson(.{ .bool = true }));
    try std.testing.expectError(error.BadBits, bits.fromJson(.null));
}

test "bit lists require arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "[2, \"x\", \"1\"]",
        .{},
    );
    const out = try bits.listFromJson(arena.allocator(), v);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqual(@as(u32, 2), out[0].sig);
    try std.testing.expect(out[1] == .x);
    try std.testing.expect(out[2] == .one);
}
