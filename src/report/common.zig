// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const ir = @import("../ir.zig");
const rule = @import("../rule.zig");

// Shared reporter vocabulary: name resolution, instance
// rendering, and severity words, so every output agrees.
pub const Index = struct {
    by_cell: std.StringHashMapUnmanaged(usize),
    ports: std.StringHashMapUnmanaged(void),
    // RTL names for the cells some finding names; see ir/names.zig.
    signals: ir.names.Names = .empty,

    pub fn build(alloc: std.mem.Allocator, mod: *const ir.types.Module) error{OutOfMemory}!Index {
        var by_cell = std.StringHashMapUnmanaged(usize).empty;
        for (mod.cells, 0..) |c, ci| try by_cell.put(alloc, c.name, ci);
        var ports = std.StringHashMapUnmanaged(void).empty;
        for (mod.ports) |p| try ports.put(alloc, p.name, {});
        return .{ .by_cell = by_cell, .ports = ports };
    }

    // An index that also knows the RTL signal of every cell these
    // findings name, for reporters that show signals.
    pub fn buildFor(
        alloc: std.mem.Allocator,
        mod: *const ir.types.Module,
        findings: []const rule.finding.Finding,
    ) error{OutOfMemory}!Index {
        var idx = try build(alloc, mod);
        var cells = std.ArrayListUnmanaged(usize).empty;
        for (findings) |f| {
            if (idx.by_cell.get(f.dst)) |ci| try cells.append(alloc, ci);
            if (f.driver) |d| if (idx.by_cell.get(d)) |ci| try cells.append(alloc, ci);
            var it = CellRefs{ .idx = &idx, .text = f.message };
            while (it.next()) |ref| try cells.append(alloc, ref.cell);
        }
        idx.signals = try ir.names.build(alloc, mod, cells.items);
        return idx;
    }
};

// Generated cell names inside free text. Only tokens holding a `$`
// can be one, and a token may run into sentence punctuation
// ("at $procdff$9."), so trailing dots, colons and commas come off
// until the rest names a cell.
const CellRef = struct { start: usize, end: usize, cell: usize };

const CellRefs = struct {
    idx: *const Index,
    text: []const u8,
    pos: usize = 0,

    fn next(self: *CellRefs) ?CellRef {
        const t = self.text;
        while (self.pos < t.len) {
            while (self.pos < t.len and !nameChar(t[self.pos])) self.pos += 1;
            const start = self.pos;
            while (self.pos < t.len and nameChar(t[self.pos])) self.pos += 1;
            var end = self.pos;
            if (std.mem.indexOfScalar(u8, t[start..end], '$') == null) continue;
            while (end > start) {
                if (self.idx.by_cell.get(t[start..end])) |ci| return .{ .start = start, .end = end, .cell = ci };
                const last = t[end - 1];
                if (last != '.' and last != ':' and last != ',') break;
                end -= 1;
            }
        }
        return null;
    }
};

fn nameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or switch (ch) {
        '_', '$', '\\', '.', ':', '/' => true,
        else => false,
    };
}

// A rule message with each generated cell name it mentions shown as
// its RTL signal, as the endpoints already are. Findings keep the
// raw text; only what a reader sees changes.
pub fn displayMessage(alloc: std.mem.Allocator, idx: *const Index, msg: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var last: usize = 0;
    var it = CellRefs{ .idx = idx, .text = msg };
    while (it.next()) |ref| {
        const sig = idx.signals.get(ref.cell) orelse continue;
        try out.appendSlice(alloc, msg[last..ref.start]);
        try out.appendSlice(alloc, sig);
        last = ref.end;
    }
    if (last == 0) return msg;
    try out.appendSlice(alloc, msg[last..]);
    return out.toOwnedSlice(alloc);
}

pub const Kind = enum { cell, port, other };

pub const Resolved = struct {
    kind: Kind,
    instance: []const u8,
    src: ?[]const u8,
    // What a designer would call it: the register or net for a
    // generated cell, else the name itself.
    signal: []const u8,
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
        return .{
            .kind = .cell,
            .instance = try joinPath(alloc, c.instance_path),
            .src = c.src,
            .signal = idx.signals.get(ci) orelse name,
        };
    }
    if (idx.ports.contains(name)) return .{ .kind = .port, .instance = "", .src = null, .signal = name };
    return .{ .kind = .other, .instance = "", .src = null, .signal = name };
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
