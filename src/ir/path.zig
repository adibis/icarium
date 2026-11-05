const std = @import("std");

// Flattened cell names carry hierarchy dot-separated; `\.` is a
// literal dot inside escaped identifiers, not a separator.
pub fn splitInstancePath(alloc: std.mem.Allocator, name: []const u8) ![][]const u8 {
    var raw: std.ArrayListUnmanaged([]const u8) = .empty;
    defer raw.deinit(alloc);
    var start: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        if (name[i] == '\\' and i + 1 < name.len and name[i + 1] == '.') {
            i += 2;
            continue;
        }
        if (name[i] == '.') {
            try raw.append(alloc, name[start..i]);
            start = i + 1;
        }
        i += 1;
    }
    try raw.append(alloc, name[start..]);
    if (raw.items.len == 0) return &.{};

    const path = try alloc.alloc([]const u8, raw.items.len - 1);
    for (raw.items[0 .. raw.items.len - 1], 0..) |seg, k|
        path[k] = try copySegment(alloc, seg);
    return path;
}

// Every segment is owned: mixed borrowed/owned returns are a
// use-after-free waiting for a refactor to trigger it.
fn copySegment(alloc: std.mem.Allocator, seg: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < seg.len) {
        if (seg[i] == '\\' and i + 1 < seg.len and seg[i + 1] == '.') {
            try out.append(alloc, '.');
            i += 2;
        } else {
            try out.append(alloc, seg[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}
