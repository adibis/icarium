// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const common = @import("common.zig");
const ir = @import("../ir.zig");
const rule = @import("../rule.zig");

// SARIF 2.1.0 rendering of the findings model for CI code
// scanning: rule metadata, dst physical locations with Yosys
// src regions, driver related locations, and hierarchy in
// logical locations. Suppressions arrive with waivers.
pub fn writeSarif(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    findings: []const rule.finding.Finding,
    version: []const u8,
) error{ OutOfMemory, WriteFailed }!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tmp = arena.allocator();

    const ordered = try tmp.dupe(rule.finding.Finding, findings);
    std.mem.sort(rule.finding.Finding, ordered, {}, rule.finding.Finding.less);
    const idx = try common.Index.build(tmp, mod);

    var rules = std.json.Array.init(tmp);
    for (rule.registry.rules) |r| {
        var short = std.json.ObjectMap.empty;
        try short.put(tmp, "text", .{ .string = r.title });
        var full = std.json.ObjectMap.empty;
        try full.put(tmp, "text", .{ .string = r.doc });
        var dflt = std.json.ObjectMap.empty;
        try dflt.put(tmp, "level", .{ .string = common.severityWord(r.severity) });
        var meta = std.json.ObjectMap.empty;
        try meta.put(tmp, "id", .{ .string = r.id });
        try meta.put(tmp, "name", .{ .string = r.id });
        try meta.put(tmp, "shortDescription", .{ .object = short });
        try meta.put(tmp, "fullDescription", .{ .object = full });
        try meta.put(tmp, "defaultConfiguration", .{ .object = dflt });
        try rules.append(.{ .object = meta });
    }

    var results = std.json.Array.init(tmp);
    for (ordered) |f| {
        var msg = std.json.ObjectMap.empty;
        try msg.put(tmp, "text", .{ .string = f.message });
        var res = std.json.ObjectMap.empty;
        try res.put(tmp, "ruleId", .{ .string = f.rule });
        try res.put(tmp, "level", .{ .string = common.severityWord(f.severity) });
        try res.put(tmp, "message", .{ .object = msg });
        var locs = std.json.Array.init(tmp);
        try locs.append(try location(tmp, mod, &idx, f.dst));
        try res.put(tmp, "locations", .{ .array = locs });
        if (f.driver) |d| {
            var rel = std.json.Array.init(tmp);
            try rel.append(try location(tmp, mod, &idx, d));
            try res.put(tmp, "relatedLocations", .{ .array = rel });
        }
        if (f.waiver) |w| {
            var sup = std.json.ObjectMap.empty;
            try sup.put(tmp, "kind", .{ .string = "external" });
            try sup.put(tmp, "justification", .{ .string = w.reason });
            var sups = std.json.Array.init(tmp);
            try sups.append(.{ .object = sup });
            try res.put(tmp, "suppressions", .{ .array = sups });
        }
        try results.append(.{ .object = res });
    }

    var driver = std.json.ObjectMap.empty;
    try driver.put(tmp, "name", .{ .string = "icarium" });
    try driver.put(tmp, "version", .{ .string = version });
    try driver.put(tmp, "rules", .{ .array = rules });
    var tool = std.json.ObjectMap.empty;
    try tool.put(tmp, "driver", .{ .object = driver });
    var run = std.json.ObjectMap.empty;
    try run.put(tmp, "tool", .{ .object = tool });
    try run.put(tmp, "results", .{ .array = results });
    var runs = std.json.Array.init(tmp);
    try runs.append(.{ .object = run });

    var root = std.json.ObjectMap.empty;
    try root.put(tmp, "$schema", .{ .string = "https://json.schemastore.org/sarif-2.1.0.json" });
    try root.put(tmp, "version", .{ .string = "2.1.0" });
    try root.put(tmp, "runs", .{ .array = runs });

    const doc: std.json.Value = .{ .object = root };
    std.json.Stringify.value(doc, .{ .whitespace = .indent_2 }, writer) catch return error.WriteFailed;
    writer.writeByte('\n') catch return error.WriteFailed;
}

// A dst or driver as one location: file region where Yosys
// recorded one, hierarchy always, bare name when neither.
fn location(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    idx: *const common.Index,
    name: []const u8,
) error{OutOfMemory}!std.json.Value {
    const r = try common.resolve(alloc, mod, idx, name);
    var loc = std.json.ObjectMap.empty;
    if (r.src) |s| {
        try loc.put(alloc, "physicalLocation", try physical(alloc, s));
    }
    const leaf = try common.leafName(alloc, name);
    const fqn = if (r.instance.len == 0)
        try std.fmt.allocPrint(alloc, "{s}/{s}", .{ mod.name, leaf })
    else
        try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ mod.name, r.instance, leaf });
    var ll = std.json.ObjectMap.empty;
    try ll.put(alloc, "fullyQualifiedName", .{ .string = fqn });
    var lls = std.json.Array.init(alloc);
    try lls.append(.{ .object = ll });
    try loc.put(alloc, "logicalLocations", .{ .array = lls });
    return .{ .object = loc };
}

fn physical(alloc: std.mem.Allocator, src: []const u8) error{OutOfMemory}!std.json.Value {
    const p = parseSrc(src);
    var art = std.json.ObjectMap.empty;
    try art.put(alloc, "uri", .{ .string = p.uri });
    var phys = std.json.ObjectMap.empty;
    try phys.put(alloc, "artifactLocation", .{ .object = art });
    if (p.region) |rg| {
        var region = std.json.ObjectMap.empty;
        try region.put(alloc, "startLine", .{ .integer = rg.start_line });
        if (rg.start_col) |c| try region.put(alloc, "startColumn", .{ .integer = c });
        if (rg.end_line) |e| try region.put(alloc, "endLine", .{ .integer = e });
        if (rg.end_col) |c| try region.put(alloc, "endColumn", .{ .integer = c });
        try phys.put(alloc, "region", .{ .object = region });
    }
    return .{ .object = phys };
}

pub const Region = struct {
    start_line: i64,
    start_col: ?i64,
    end_line: ?i64,
    end_col: ?i64,
};

pub const ParsedSrc = struct {
    uri: []const u8,
    region: ?Region,
};

// Yosys src shapes: path:line.col-line.col, path:line.col,
// path:line. Anything else degrades to a bare uri; guessing
// line numbers would mislead the reader of the report.
pub fn parseSrc(src: []const u8) ParsedSrc {
    const first = if (std.mem.indexOfScalar(u8, src, ' ')) |sp| src[0..sp] else src;
    const colon = std.mem.lastIndexOfScalar(u8, first, ':') orelse return .{ .uri = src, .region = null };
    const tail = first[colon + 1 ..];
    if (tail.len == 0) return .{ .uri = src, .region = null };
    const dash = std.mem.indexOfScalar(u8, tail, '-');
    const start = if (dash) |d| tail[0..d] else tail;
    const end = if (dash) |d| tail[d + 1 ..] else null;
    const sl = parsePoint(start) orelse return .{ .uri = src, .region = null };
    if (end) |e| {
        const el = parsePoint(e) orelse return .{ .uri = src, .region = null };
        return .{
            .uri = first[0..colon],
            .region = .{ .start_line = sl[0], .start_col = sl[1], .end_line = el[0], .end_col = el[1] },
        };
    }
    return .{
        .uri = first[0..colon],
        .region = .{ .start_line = sl[0], .start_col = sl[1], .end_line = null, .end_col = null },
    };
}

// A line.col point; line-only reads as column-unknown, and
// non-numeric text rejects the whole region, never half.
fn parsePoint(s: []const u8) ?struct { i64, ?i64 } {
    if (s.len == 0) return null;
    if (std.mem.indexOfScalar(u8, s, '.')) |d| {
        const line = std.fmt.parseInt(i64, s[0..d], 10) catch return null;
        const col = std.fmt.parseInt(i64, s[d + 1 ..], 10) catch return null;
        if (line <= 0 or col <= 0) return null;
        return .{ line, col };
    }
    const line = std.fmt.parseInt(i64, s, 10) catch return null;
    if (line <= 0) return null;
    return .{ line, null };
}
