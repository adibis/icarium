const std = @import("std");
const bits = @import("bits.zig");
const types = @import("types.zig");

pub const TypeCount = struct { name: []const u8, count: usize };

pub const Summary = struct {
    cells: usize,
    unique_bits: usize,
    with_src: usize,
};

pub fn summarize(alloc: std.mem.Allocator, mod: *const types.Module) !Summary {
    var seen = std.AutoHashMapUnmanaged(u32, void){};
    defer seen.deinit(alloc);
    for (mod.ports) |p| try markBits(alloc, &seen, p.bits);
    for (mod.cells) |c| for (c.ports) |p| try markBits(alloc, &seen, p.bits);

    var with_src: usize = 0;
    for (mod.cells) |c| if (c.src != null) {
        with_src += 1;
    };
    return .{ .cells = mod.cells.len, .unique_bits = seen.count(), .with_src = with_src };
}

fn markBits(alloc: std.mem.Allocator, seen: *std.AutoHashMapUnmanaged(u32, void), list: []const bits.Bit) !void {
    for (list) |b| switch (b) {
        .sig => |s| try seen.put(alloc, s, {}),
        else => {},
    };
}

// Sorted by name so repeated runs diff cleanly.
pub fn histogram(alloc: std.mem.Allocator, mod: *const types.Module) ![]TypeCount {
    var counts = std.StringHashMapUnmanaged(usize){};
    defer counts.deinit(alloc);
    for (mod.cells) |c| {
        const slot = try counts.getOrPut(alloc, c.type);
        slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
    }
    const out = try alloc.alloc(TypeCount, counts.count());
    var it = counts.iterator();
    var i: usize = 0;
    while (it.next()) |entry| {
        out[i] = .{ .name = entry.key_ptr.*, .count = entry.value_ptr.* };
        i += 1;
    }
    std.mem.sort(TypeCount, out, {}, struct {
        fn less(_: void, a: TypeCount, b: TypeCount) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    return out;
}
