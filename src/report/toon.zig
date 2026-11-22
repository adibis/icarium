// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const common = @import("common.zig");
const crossing = @import("../crossing.zig");
const ir = @import("../ir.zig");
const rule = @import("../rule.zig");

// TOON emission (toon-spec 4.4, working draft): findings and
// crossings as root tabular arrays for token-lean LLM prompts.
// JSON stays canonical; TOON is a rendering with no reader in
// the binary. Pipe-delimited: prose carries commas far more
// often than pipes, so fewer cells need quoting.
pub const delimiter: u8 = '|';

const finding_fields = [_][]const u8{
    "rule",          "severity",        "title",
    "dst",           "dst_signal",      "dst_kind",
    "dst_instance",  "dst_src",         "driver",
    "driver_signal", "driver_kind",     "driver_instance",
    "driver_src",    "message",         "waiver_id",
    "waiver_reason", "waiver_location",
};

pub fn writeFindingsToon(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    findings: []const rule.finding.Finding,
) error{ OutOfMemory, WriteFailed }!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tmp = arena.allocator();
    const ordered = try tmp.dupe(rule.finding.Finding, findings);
    std.mem.sort(rule.finding.Finding, ordered, {}, rule.finding.Finding.less);
    const idx = try common.Index.buildFor(tmp, mod, ordered);
    if (ordered.len == 0) {
        writer.writeAll("[]") catch return error.WriteFailed;
        return;
    }
    try writeHeader(writer, ordered.len, &finding_fields);
    for (ordered) |f| {
        const dst = try common.resolve(tmp, mod, &idx, f.dst);
        var cells = std.ArrayListUnmanaged(?[]const u8).empty;
        try cells.appendSlice(tmp, &.{
            f.rule,       common.severityWord(f.severity), common.ruleTitle(f.rule),
            f.dst,        dst.signal,                      kindWord(dst.kind),
            dst.instance, dst.src,
        });
        if (f.driver) |d| {
            const drv = try common.resolve(tmp, mod, &idx, d);
            try cells.appendSlice(tmp, &.{ d, drv.signal, kindWord(drv.kind), drv.instance, drv.src });
        } else {
            try cells.appendSlice(tmp, &.{ null, null, null, null, null });
        }
        try cells.append(tmp, try common.displayMessage(tmp, &idx, f.message));
        if (f.waiver) |w| {
            try cells.appendSlice(tmp, &.{ w.id, w.reason, w.location });
        } else {
            try cells.appendSlice(tmp, &.{ null, null, null });
        }
        try writeRow(writer, cells.items);
    }
}

const crossing_fields = [_][]const u8{
    "id",            "kind",
    "src",           "src_kind",
    "src_instance",  "dst",
    "dst_kind",      "dst_instance",
    "src_clock",     "dst_clock",
    "async_per_sdc", "width",
    "hops",
};

pub fn writeCrossingsToon(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    report: *const crossing.enumerate.Report,
) error{ OutOfMemory, WriteFailed }!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tmp = arena.allocator();
    const idx = try common.Index.build(tmp, mod);
    if (report.crossings.len == 0) {
        writer.writeAll("[]") catch return error.WriteFailed;
        return;
    }
    try writeHeader(writer, report.crossings.len, &crossing_fields);
    for (report.crossings) |x| {
        const src_name: []const u8 = if (x.src.cell) |c| mod.cells[c].name else x.src.port;
        const dst_name: []const u8 = if (x.dst.cell) |c| mod.cells[c].name else x.dst.port;
        const src = try common.resolve(tmp, mod, &idx, src_name);
        const dst = try common.resolve(tmp, mod, &idx, dst_name);
        var cells = std.ArrayListUnmanaged(Cell).empty;
        try cells.appendSlice(tmp, &.{
            .{ .text = x.id },                .{ .text = @tagName(x.kind) },
            .{ .text = src_name },            .{ .text = kindWord(src.kind) },
            .{ .text = src.instance },        .{ .text = dst_name },
            .{ .text = kindWord(dst.kind) },  .{ .text = dst.instance },
            .{ .text = x.src_clk },           .{ .text = x.dst_clk },
            .{ .bool = x.async_per_sdc },     .{ .int = @intCast(@max(x.lanes.len, 1)) },
            .{ .int = @intCast(x.hops.len) },
        });
        try writeTypedRow(writer, cells.items);
    }
}

const Cell = union(enum) {
    text: []const u8,
    bool: bool,
    int: i64,
};

fn kindWord(k: common.Kind) []const u8 {
    return switch (k) {
        .cell => "cell",
        .port => "port",
        .other => "other",
    };
}

// Keyless root tabular header; rows follow at depth +1. No
// trailing newline anywhere: the spec forbids it.
fn writeHeader(writer: *std.Io.Writer, n: usize, fields: []const []const u8) error{WriteFailed}!void {
    writer.print("[{d}|]{{", .{n}) catch return error.WriteFailed;
    for (fields, 0..) |f, i| {
        if (i > 0) writer.writeByte(delimiter) catch return error.WriteFailed;
        writer.writeAll(f) catch return error.WriteFailed;
    }
    writer.writeAll("}:") catch return error.WriteFailed;
}

fn writeRow(writer: *std.Io.Writer, cells: []const ?[]const u8) error{WriteFailed}!void {
    writer.writeAll("\n  ") catch return error.WriteFailed;
    for (cells, 0..) |c, i| {
        if (i > 0) writer.writeByte(delimiter) catch return error.WriteFailed;
        if (c) |s| {
            writeValue(writer, s) catch return error.WriteFailed;
        } else {
            writer.writeAll("null") catch return error.WriteFailed;
        }
    }
}

fn writeTypedRow(writer: *std.Io.Writer, cells: []const Cell) error{WriteFailed}!void {
    writer.writeAll("\n  ") catch return error.WriteFailed;
    for (cells, 0..) |c, i| {
        if (i > 0) writer.writeByte(delimiter) catch return error.WriteFailed;
        switch (c) {
            .text => |s| writeValue(writer, s) catch return error.WriteFailed,
            .bool => |b| writer.writeAll(if (b) "true" else "false") catch return error.WriteFailed,
            .int => |v| writer.print("{d}", .{v}) catch return error.WriteFailed,
        }
    }
}

// Quoting per §7.2 against the document delimiter; escaping
// per §7.1. Non-ASCII bytes pass through as literal UTF-8.
fn writeValue(writer: *std.Io.Writer, s: []const u8) error{WriteFailed}!void {
    if (!needsQuotes(s)) {
        writer.writeAll(s) catch return error.WriteFailed;
        return;
    }
    writer.writeByte('"') catch return error.WriteFailed;
    for (s) |c| {
        switch (c) {
            '\\' => writer.writeAll("\\\\") catch return error.WriteFailed,
            '"' => writer.writeAll("\\\"") catch return error.WriteFailed,
            '\n' => writer.writeAll("\\n") catch return error.WriteFailed,
            '\r' => writer.writeAll("\\r") catch return error.WriteFailed,
            '\t' => writer.writeAll("\\t") catch return error.WriteFailed,
            else => {
                if (c < 0x20) {
                    writer.print("\\u00{x:0>2}", .{c}) catch return error.WriteFailed;
                } else {
                    writer.writeByte(c) catch return error.WriteFailed;
                }
            },
        }
    }
    writer.writeByte('"') catch return error.WriteFailed;
}

fn needsQuotes(s: []const u8) bool {
    if (s.len == 0) return true;
    if (s[0] == ' ' or s[0] == '\t' or s[s.len - 1] == ' ' or s[s.len - 1] == '\t') return true;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) return true;
    if (numericLike(s)) return true;
    for (s) |c| {
        if (c == ':' or c == '"' or c == '\\' or c == '[' or c == ']' or
            c == '{' or c == '}' or c == delimiter or c < 0x20) return true;
    }
    if (s[0] == '-' or s[0] == '#') return true;
    return false;
}

// ASCII numeric-like per §7.2: optional sign, digits, optional
// fraction and exponent. Quoted on emit so values survive as
// strings; the decoder never sees a bare numeric string.
fn numericLike(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    const int_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == int_start) return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == frac_start) return false;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == exp_start) return false;
    }
    return i == s.len;
}
