// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const Bit = union(enum) {
    sig: u32,
    zero,
    one,
    x,
    z,
};

pub fn fromJson(v: std.json.Value) error{ BadBits, NegativeBit }!Bit {
    switch (v) {
        .integer => |i| {
            if (i < 0) return error.NegativeBit;
            return .{ .sig = @intCast(i) };
        },
        .string => |s| {
            if (std.mem.eql(u8, s, "0")) return .zero;
            if (std.mem.eql(u8, s, "1")) return .one;
            if (std.mem.eql(u8, s, "x")) return .x;
            if (std.mem.eql(u8, s, "z")) return .z;
            return error.BadBits;
        },
        else => return error.BadBits,
    }
}

pub fn listFromJson(alloc: std.mem.Allocator, v: std.json.Value) ![]Bit {
    if (v != .array) return error.BadShape;
    const items = v.array.items;
    const out = try alloc.alloc(Bit, items.len);
    for (items, 0..) |item, i| out[i] = try fromJson(item);
    return out;
}

// No signal bits: the net is tied off, so consumers
// see the constant alone. Empty means malformed, not const.
pub fn allConst(s: []const Bit) bool {
    if (s.len == 0) return false;
    for (s) |b| if (b == .sig) return false;
    return true;
}

// Only constants are statically known selects; anything else
// needs value propagation we deliberately do not have (v1).
pub fn constSel(s: []const Bit) ?bool {
    if (s.len == 0) return null;
    var val: ?bool = null;
    for (s) |b| switch (b) {
        .zero => {
            if (val != null and val.? != false) return null;
            val = false;
        },
        .one => {
            if (val != null and val.? != true) return null;
            val = true;
        },
        else => return null,
    };
    return val;
}

// Strict 0/1: x/z are unknown, not driven values,
// and a reset leg must be a known value to count.
pub fn is01Const(list: []const Bit) bool {
    if (list.len == 0) return false;
    for (list) |b| switch (b) {
        .zero, .one => {},
        else => return false,
    };
    return true;
}
