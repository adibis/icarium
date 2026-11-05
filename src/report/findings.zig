const std = @import("std");
const ir = @import("../ir.zig");
const rule = @import("../rule.zig");

pub const schema_version = "1.0";

// Native findings.json: rule-grouped verdicts with receiver and
// driver endpoints resolved to cells, instance paths, and Yosys
// src locations. Reporters render this model; they never analyze.
pub const Options = struct {
    minify: bool = false,
};

pub fn writeJson(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    findings: []const rule.finding.Finding,
) error{ OutOfMemory, WriteFailed }!void {
    try writeJsonOptions(alloc, writer, mod, findings, .{});
}

pub fn writeJsonOptions(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    findings: []const rule.finding.Finding,
    opts: Options,
) error{ OutOfMemory, WriteFailed }!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tmp = arena.allocator();

    const ordered = try tmp.dupe(rule.finding.Finding, findings);
    std.mem.sort(rule.finding.Finding, ordered, {}, rule.finding.Finding.less);

    var by_cell = std.StringHashMapUnmanaged(usize).empty;
    for (mod.cells, 0..) |c, ci| try by_cell.put(tmp, c.name, ci);
    var ports = std.StringHashMapUnmanaged(void).empty;
    for (mod.ports) |p| try ports.put(tmp, p.name, {});

    var errors: u32 = 0;
    var warnings: u32 = 0;
    var notes: u32 = 0;
    for (ordered) |f| switch (f.severity) {
        .err => errors += 1,
        .warn => warnings += 1,
        .note => notes += 1,
    };

    var groups = std.json.Array.init(tmp);
    var i: usize = 0;
    while (i < ordered.len) {
        var j = i + 1;
        while (j < ordered.len and std.mem.eql(u8, ordered[j].rule, ordered[i].rule)) j += 1;
        var items = std.json.Array.init(tmp);
        for (ordered[i..j]) |f| {
            var item = std.json.ObjectMap.empty;
            try item.put(tmp, "dst", try endpoint(tmp, mod, &by_cell, &ports, f.dst));
            if (f.driver) |d| {
                try item.put(tmp, "driver", try endpoint(tmp, mod, &by_cell, &ports, d));
            } else {
                try item.put(tmp, "driver", .null);
            }
            try item.put(tmp, "message", .{ .string = f.message });
            try item.put(tmp, "waiver", .null);
            try items.append(.{ .object = item });
        }
        var g = std.json.ObjectMap.empty;
        try g.put(tmp, "rule", .{ .string = ordered[i].rule });
        try g.put(tmp, "severity", .{ .string = severityWord(ordered[i].severity) });
        try g.put(tmp, "title", .{ .string = ruleTitle(ordered[i].rule) });
        try g.put(tmp, "items", .{ .array = items });
        try groups.append(.{ .object = g });
        i = j;
    }

    var summary = std.json.ObjectMap.empty;
    try summary.put(tmp, "errors", .{ .integer = errors });
    try summary.put(tmp, "warnings", .{ .integer = warnings });
    try summary.put(tmp, "notes", .{ .integer = notes });

    var design = std.json.ObjectMap.empty;
    try design.put(tmp, "top", .{ .string = mod.name });

    var root = std.json.ObjectMap.empty;
    try root.put(tmp, "schema_version", .{ .string = schema_version });
    try root.put(tmp, "design", .{ .object = design });
    try root.put(tmp, "summary", .{ .object = summary });
    try root.put(tmp, "groups", .{ .array = groups });

    const ws: std.json.Stringify.Options = .{ .whitespace = if (opts.minify) .minified else .indent_2 };
    const doc: std.json.Value = .{ .object = root };
    std.json.Stringify.value(doc, ws, writer) catch return error.WriteFailed;
    if (!opts.minify) writer.writeByte('\n') catch return error.WriteFailed;
}

// Cells resolve to instance + src; ports and unknown names
// degrade to bare names rather than invented locations.
fn endpoint(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    by_cell: *const std.StringHashMapUnmanaged(usize),
    ports: *const std.StringHashMapUnmanaged(void),
    name: []const u8,
) error{OutOfMemory}!std.json.Value {
    var ep = std.json.ObjectMap.empty;
    try ep.put(alloc, "name", .{ .string = name });
    if (by_cell.get(name)) |ci| {
        const c = mod.cells[ci];
        try ep.put(alloc, "kind", .{ .string = "cell" });
        try ep.put(alloc, "instance", .{ .string = try joinPath(alloc, c.instance_path) });
        if (c.src) |s| {
            try ep.put(alloc, "src", .{ .string = s });
        } else {
            try ep.put(alloc, "src", .null);
        }
    } else if (ports.contains(name)) {
        try ep.put(alloc, "kind", .{ .string = "port" });
        try ep.put(alloc, "instance", .{ .string = "" });
        try ep.put(alloc, "src", .null);
    } else {
        try ep.put(alloc, "kind", .{ .string = "other" });
        try ep.put(alloc, "instance", .{ .string = "" });
        try ep.put(alloc, "src", .null);
    }
    return .{ .object = ep };
}

// Slash-joined hierarchy: dots collide with escaped Yosys
// identifiers, while waiver globs already speak slashes.
fn joinPath(alloc: std.mem.Allocator, segs: [][]const u8) error{OutOfMemory}![]const u8 {
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

fn severityWord(s: rule.registry.Severity) []const u8 {
    return switch (s) {
        .err => "error",
        .warn => "warning",
        .note => "note",
    };
}

fn ruleTitle(id: []const u8) []const u8 {
    if (rule.registry.find(id)) |r| return r.title;
    return "";
}
