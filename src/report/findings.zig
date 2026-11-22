// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const common = @import("common.zig");
const ir = @import("../ir.zig");
const rule = @import("../rule.zig");

pub const schema_version = "1.1";

// Native findings.json: rule-grouped verdicts with receiver and
// driver endpoints resolved to cells, RTL signals, instance paths,
// and Yosys src locations. `name` stays the netlist key waivers and
// baselines match; `signal` is what the designer wrote. Reporters render this model; they never analyze.
pub const Options = struct {
    minify: bool = false,
};

pub fn writeJson(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    findings: []const rule.finding.Finding,
    unmatched: []const []const u8,
    carried_over: u32,
) error{ OutOfMemory, WriteFailed }!void {
    try writeJsonOptions(alloc, writer, mod, findings, unmatched, carried_over, .{});
}

pub fn writeJsonOptions(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    findings: []const rule.finding.Finding,
    unmatched: []const []const u8,
    carried_over: u32,
    opts: Options,
) error{ OutOfMemory, WriteFailed }!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tmp = arena.allocator();

    const ordered = try tmp.dupe(rule.finding.Finding, findings);
    std.mem.sort(rule.finding.Finding, ordered, {}, rule.finding.Finding.less);

    const idx = try common.Index.buildFor(tmp, mod, ordered);

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
        // Group severity is the max over items: mixed rules record
        // notes beside defects, so the first-sorted item would lie.
        // Enum order is severity rank (err < warn < note).
        var gsev = rule.registry.Severity.note;
        for (ordered[i..j]) |f| {
            if (@backingInt(f.severity) < @backingInt(gsev)) gsev = f.severity;
        }
        var items = std.json.Array.init(tmp);
        for (ordered[i..j]) |f| {
            var item = std.json.ObjectMap.empty;
            try item.put(tmp, "severity", .{ .string = common.severityWord(f.severity) });
            try item.put(tmp, "dst", try endpoint(tmp, mod, &idx, f.dst));
            if (f.driver) |d| {
                try item.put(tmp, "driver", try endpoint(tmp, mod, &idx, d));
            } else {
                try item.put(tmp, "driver", .null);
            }
            try item.put(tmp, "message", .{ .string = try common.displayMessage(tmp, &idx, f.message) });
            if (f.waiver) |w| {
                var wo = std.json.ObjectMap.empty;
                try wo.put(tmp, "waiver_id", .{ .string = w.id });
                try wo.put(tmp, "reason", .{ .string = w.reason });
                if (w.location) |l| {
                    try wo.put(tmp, "location", .{ .string = l });
                } else {
                    try wo.put(tmp, "location", .null);
                }
                try item.put(tmp, "waiver", .{ .object = wo });
            } else {
                try item.put(tmp, "waiver", .null);
            }
            try items.append(.{ .object = item });
        }
        var g = std.json.ObjectMap.empty;
        try g.put(tmp, "rule", .{ .string = ordered[i].rule });
        try g.put(tmp, "severity", .{ .string = common.severityWord(gsev) });
        try g.put(tmp, "title", .{ .string = common.ruleTitle(ordered[i].rule) });
        try g.put(tmp, "items", .{ .array = items });
        try groups.append(.{ .object = g });
        i = j;
    }

    var summary = std.json.ObjectMap.empty;
    try summary.put(tmp, "errors", .{ .integer = errors });
    try summary.put(tmp, "warnings", .{ .integer = warnings });
    try summary.put(tmp, "notes", .{ .integer = notes });
    try summary.put(tmp, "carried_over", .{ .integer = carried_over });

    var design = std.json.ObjectMap.empty;
    try design.put(tmp, "top", .{ .string = mod.name });

    var unw = std.json.Array.init(tmp);
    for (unmatched) |id| try unw.append(.{ .string = id });
    var root = std.json.ObjectMap.empty;
    try root.put(tmp, "schema_version", .{ .string = schema_version });
    try root.put(tmp, "design", .{ .object = design });
    try root.put(tmp, "summary", .{ .object = summary });
    try root.put(tmp, "groups", .{ .array = groups });
    try root.put(tmp, "unmatched_waivers", .{ .array = unw });

    const ws: std.json.Stringify.Options = .{ .whitespace = if (opts.minify) .minified else .indent_2 };
    const doc: std.json.Value = .{ .object = root };
    std.json.Stringify.value(doc, ws, writer) catch return error.WriteFailed;
    if (!opts.minify) writer.writeByte('\n') catch return error.WriteFailed;
}

fn endpoint(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    idx: *const common.Index,
    name: []const u8,
) error{OutOfMemory}!std.json.Value {
    const r = try common.resolve(alloc, mod, idx, name);
    const kind: []const u8 = switch (r.kind) {
        .cell => "cell",
        .port => "port",
        .other => "other",
    };
    var ep = std.json.ObjectMap.empty;
    try ep.put(alloc, "name", .{ .string = name });
    try ep.put(alloc, "signal", .{ .string = r.signal });
    try ep.put(alloc, "kind", .{ .string = kind });
    try ep.put(alloc, "instance", .{ .string = r.instance });
    if (r.src) |s| {
        try ep.put(alloc, "src", .{ .string = s });
    } else {
        try ep.put(alloc, "src", .null);
    }
    return .{ .object = ep };
}
