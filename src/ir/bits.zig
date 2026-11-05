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
