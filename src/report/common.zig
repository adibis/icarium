const std = @import("std");
const ir = @import("../ir.zig");
const rule = @import("../rule.zig");

// Shared reporter vocabulary: name resolution, instance
// rendering, and severity words, so every output agrees.
pub const Index = struct {
    by_cell: std.StringHashMapUnmanaged(usize),
    ports: std.StringHashMapUnmanaged(void),

    pub fn build(alloc: std.mem.Allocator, mod: *const ir.types.Module) error{OutOfMemory}!Index {
        var by_cell = std.StringHashMapUnmanaged(usize).empty;
        for (mod.cells, 0..) |c, ci| try by_cell.put(alloc, c.name, ci);
        var ports = std.StringHashMapUnmanaged(void).empty;
        for (mod.ports) |p| try ports.put(alloc, p.name, {});
        return .{ .by_cell = by_cell, .ports = ports };
    }
};

pub const Kind = enum { cell, port, other };

pub const Resolved = struct {
    kind: Kind,
    instance: []const u8,
    src: ?[]const u8,
};

// Cells resolve to instance + src; ports and unknown names
// degrade to bare names rather than invented locations.
pub fn resolve(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    idx: *const Index,
    name: []const u8,
) error{OutOfMemory}!Resolved {
    if (idx.by_cell.get(name)) |ci| {
        const c = mod.cells[ci];
        return .{ .kind = .cell, .instance = try joinPath(alloc, c.instance_path), .src = c.src };
    }
    if (idx.ports.contains(name)) return .{ .kind = .port, .instance = "", .src = null };
    return .{ .kind = .other, .instance = "", .src = null };
}

// The leaf below the instance path: flattened Yosys names
// embed hierarchy, so the FQN takes the last segment, not
// the whole name (which would repeat the path).
pub fn leafName(alloc: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        if (name[i] == '\\' and i + 1 < name.len and name[i + 1] == '.') {
            i += 2;
            continue;
        }
        if (name[i] == '.') start = i + 1;
        i += 1;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var j = start;
    while (j < name.len) {
        if (name[j] == '\\' and j + 1 < name.len and name[j + 1] == '.') {
            try out.append(alloc, '.');
            j += 2;
        } else {
            try out.append(alloc, name[j]);
            j += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

// Slash-joined hierarchy: dots collide with escaped Yosys
// identifiers, while waiver globs already speak slashes.
pub fn joinPath(alloc: std.mem.Allocator, segs: [][]const u8) error{OutOfMemory}![]const u8 {
    if (segs.len == 0) return "";
    var len: usize = 0;
    for (segs) |s| len += s.len + 1;
    const out = try alloc.alloc(u8, len - 1);
    var pos: usize = 0;
    for (segs, 0..) |s, k| {
        if (k > 0) {
            out[pos] = '/';
            pos += 1;
        }
        @memcpy(out[pos .. pos + s.len], s);
        pos += s.len;
    }
    return out;
}

pub fn severityWord(s: rule.registry.Severity) []const u8 {
    return switch (s) {
        .err => "error",
        .warn => "warning",
        .note => "note",
    };
}

pub fn ruleTitle(id: []const u8) []const u8 {
    if (rule.registry.find(id)) |r| return r.title;
    return "";
}

pub const FileLoc = struct {
    file: []const u8,
    start_line: i64,
    start_col: ?i64,
    end_line: ?i64,
    end_col: ?i64,
};

// A Yosys src string as a tool-joinable file location; the
// sarif parser owns the grammar, maps only reshape it.
pub fn fileLoc(src: []const u8) ?FileLoc {
    const p = @import("sarif.zig").parseSrc(src);
    const rg = p.region orelse return null;
    return .{
        .file = p.uri,
        .start_line = rg.start_line,
        .start_col = rg.start_col,
        .end_line = rg.end_line,
        .end_col = rg.end_col,
    };
}

pub fn locValue(alloc: std.mem.Allocator, l: FileLoc) error{OutOfMemory}!std.json.Value {
    var o = std.json.ObjectMap.empty;
    try o.put(alloc, "file", .{ .string = l.file });
    try o.put(alloc, "start_line", .{ .integer = l.start_line });
    if (l.start_col) |c| {
        try o.put(alloc, "start_column", .{ .integer = c });
    } else {
        try o.put(alloc, "start_column", .null);
    }
    if (l.end_line) |e| {
        try o.put(alloc, "end_line", .{ .integer = e });
    } else {
        try o.put(alloc, "end_line", .null);
    }
    if (l.end_col) |c| {
        try o.put(alloc, "end_column", .{ .integer = c });
    } else {
        try o.put(alloc, "end_column", .null);
    }
    return .{ .object = o };
}
