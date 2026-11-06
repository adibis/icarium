const std = @import("std");
const clock = @import("icarium").clock;
const crossing = @import("icarium").crossing;
const ir = @import("icarium").ir;
const report = @import("icarium").report;
const rule = @import("icarium").rule;
const sdc = @import("icarium").sdc;
const sync = @import("icarium").sync;

// Test-only TOON reader for exactly the subset the emitter
// writes: root [] or [N|]{fields}: plus indented rows. Strict
// on counts, indent, and escapes, so goldens cannot drift.
const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    null,
};

const Doc = struct {
    fields: [][]const u8,
    rows: [][]Value,
};

const DecodeError = error{ OutOfMemory, BadToon };

fn decode(alloc: std.mem.Allocator, text: []const u8) DecodeError!Doc {
    const body = std.mem.trimEnd(u8, text, "\n");
    if (std.mem.eql(u8, body, "[]")) return .{ .fields = &.{}, .rows = &.{} };
    var lines = std.mem.splitScalar(u8, body, '\n');
    const header = lines.next() orelse return error.BadToon;
    const fields = try parseHeader(alloc, header);
    const n = try headerCount(header);
    var rows = std.ArrayListUnmanaged([]Value).empty;
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) return error.BadToon;
        if (!std.mem.startsWith(u8, line, "  ") or (line.len > 2 and line[2] == ' ')) return error.BadToon;
        const cells = try splitRow(alloc, line[2..]);
        if (cells.len != fields.len) return error.BadToon;
        var vals = std.ArrayListUnmanaged(Value).empty;
        for (cells) |c| try vals.append(alloc, try infer(alloc, c));
        try rows.append(alloc, try vals.toOwnedSlice(alloc));
        count += 1;
    }
    if (count != n) return error.BadToon;
    return .{ .fields = fields, .rows = try rows.toOwnedSlice(alloc) };
}

fn parseHeader(alloc: std.mem.Allocator, h: []const u8) DecodeError![][]const u8 {
    if (!std.mem.startsWith(u8, h, "[") or !std.mem.endsWith(u8, h, "}:")) return error.BadToon;
    const lb = std.mem.indexOfScalar(u8, h, ']') orelse return error.BadToon;
    const seg = h[1..lb];
    if (!std.mem.endsWith(u8, seg, "|")) return error.BadToon;
    _ = std.fmt.parseInt(usize, seg[0 .. seg.len - 1], 10) catch return error.BadToon;
    const fb = std.mem.indexOfScalar(u8, h, '{') orelse return error.BadToon;
    if (fb != lb + 1) return error.BadToon;
    const list = h[fb + 1 .. h.len - 2];
    var out = std.ArrayListUnmanaged([]const u8).empty;
    var it = std.mem.splitScalar(u8, list, '|');
    while (it.next()) |f| {
        if (f.len == 0) return error.BadToon;
        try out.append(alloc, f);
    }
    return out.toOwnedSlice(alloc);
}

fn headerCount(h: []const u8) DecodeError!usize {
    const lb = std.mem.indexOfScalar(u8, h, ']') orelse return error.BadToon;
    const seg = h[1..lb];
    return std.fmt.parseInt(usize, seg[0 .. seg.len - 1], 10) catch error.BadToon;
}

fn splitRow(alloc: std.mem.Allocator, line: []const u8) DecodeError![][]const u8 {
    var out = std.ArrayListUnmanaged([]const u8).empty;
    var i: usize = 0;
    var start: usize = 0;
    var quoted = false;
    while (i < line.len) {
        if (quoted) {
            if (line[i] == '\\') {
                i += 2;
                continue;
            }
            if (line[i] == '"') quoted = false;
            i += 1;
        } else if (line[i] == '"') {
            quoted = true;
            i += 1;
        } else if (line[i] == '|') {
            try out.append(alloc, line[start..i]);
            i += 1;
            start = i;
        } else {
            i += 1;
        }
    }
    if (quoted) return error.BadToon;
    try out.append(alloc, line[start..]);
    return out.toOwnedSlice(alloc);
}

fn infer(alloc: std.mem.Allocator, tok: []const u8) DecodeError!Value {
    if (tok.len >= 2 and tok[0] == '"') {
        if (tok[tok.len - 1] != '"') return error.BadToon;
        return .{ .string = try unescape(alloc, tok[1 .. tok.len - 1]) };
    }
    if (std.mem.eql(u8, tok, "null")) return .null;
    if (std.mem.eql(u8, tok, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, tok, "false")) return .{ .bool = false };
    if (isInt(tok)) return .{ .int = std.fmt.parseInt(i64, tok, 10) catch return error.BadToon };
    return .{ .string = tok };
}

fn isInt(tok: []const u8) bool {
    if (tok.len == 0) return false;
    var i: usize = 0;
    if (tok[0] == '-') {
        if (tok.len == 1) return false;
        i = 1;
    }
    for (tok[i..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn unescape(alloc: std.mem.Allocator, s: []const u8) DecodeError![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '\\') {
            try out.append(alloc, s[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= s.len) return error.BadToon;
        switch (s[i + 1]) {
            '\\' => try out.append(alloc, '\\'),
            '"' => try out.append(alloc, '"'),
            'n' => try out.append(alloc, '\n'),
            'r' => try out.append(alloc, '\r'),
            't' => try out.append(alloc, '\t'),
            'u' => {
                if (i + 5 >= s.len) return error.BadToon;
                const cp = std.fmt.parseInt(u21, s[i + 2 .. i + 6], 16) catch return error.BadToon;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return error.BadToon;
                try out.appendSlice(alloc, buf[0..len]);
                i += 6;
                continue;
            },
            else => return error.BadToon,
        }
        i += 2;
    }
    return out.toOwnedSlice(alloc);
}

const netlist =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "attributes": {"src": "top.sv:4.3-4.20"},
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [6]}
    \\        },
    \\        "mid": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [6], "Q": [7]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [7], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

fn emitFindings(fs: []rule.finding.Finding) ![]u8 {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try report.toon.writeFindingsToon(std.testing.allocator, &aw.writer, &mod, fs);
    return std.testing.allocator.dupe(u8, aw.written());
}

test "toon golden pins quoting of adversarial values" {
    var fs = [_]rule.finding.Finding{
        .{
            .rule = "CDC-001",
            .severity = .err,
            .dst = "d",
            .driver = "src",
            .message = "pipe|colon:quote\"back\\slash[bracket]{brace} #hash -dash",
            .waiver = .{ .id = "w1", .reason = "  padded  ", .location = null },
        },
        .{
            .rule = "CDC-002",
            .severity = .warn,
            .dst = "mid",
            .message = "42",
        },
    };
    const bytes = try emitFindings(&fs);
    defer std.testing.allocator.free(bytes);
    const want =
        \\[2|]{rule|severity|title|dst|dst_kind|dst_instance|dst_src|driver|driver_kind|driver_instance|driver_src|message|waiver_id|waiver_reason|waiver_location}:
        \\  CDC-001|error|Unsynchronized control crossing|d|port|""|null|src|cell|""|"top.sv:4.3-4.20"|"pipe|colon:quote\"back\\slash[bracket]{brace} #hash -dash"|w1|"  padded  "|null
        \\  CDC-002|warning|Insufficient synchronizer depth|mid|cell|""|null|null|null|null|null|"42"|null|null|null
    ;
    try std.testing.expectEqualStrings(want, bytes);
}

test "toon findings round-trip through the test decoder" {
    var fs = [_]rule.finding.Finding{
        .{ .rule = "CDC-001", .severity = .err, .dst = "mid", .driver = "src", .message = "plain words" },
        .{ .rule = "RDC-006", .severity = .warn, .dst = "ghost", .message = "m3" },
    };
    const bytes = try emitFindings(&fs);
    defer std.testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try decode(arena.allocator(), bytes);
    try std.testing.expectEqual(@as(usize, 15), doc.fields.len);
    try std.testing.expectEqual(@as(usize, 2), doc.rows.len);
    try std.testing.expectEqualStrings("CDC-001", doc.rows[0][0].string);
    try std.testing.expectEqualStrings("mid", doc.rows[0][3].string);
    try std.testing.expectEqualStrings("src", doc.rows[0][7].string);
    try std.testing.expectEqualStrings("top.sv:4.3-4.20", doc.rows[0][10].string);
    try std.testing.expect(doc.rows[0][12] == .null);
    try std.testing.expectEqualStrings("ghost", doc.rows[1][3].string);
    try std.testing.expect(doc.rows[1][7] == .null);
}

test "toon empty findings emit a bare root array" {
    const bytes = try emitFindings(&.{});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("[]", bytes);
}

test "toon decoder rejects miscounts and bad cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadToon, decode(arena.allocator(), "[2|]{a|b}:\n  1|2"));
    try std.testing.expectError(error.BadToon, decode(arena.allocator(), "[1|]{a|b}:\n  1"));
    try std.testing.expectError(error.BadToon, decode(arena.allocator(), "[1|]{a|b}:\n   1|2"));
    try std.testing.expectError(error.BadToon, decode(arena.allocator(), "[1|]{a|b}:\n  \"x|2"));
}

const sdc_text =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports d]
;

test "toon crossings round-trip structurally" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    var sdc_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sdc_arena.deinit();
    var warns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    const cmds = try sdc.tokens.parseCommands(sdc_arena.allocator(), sdc_text, &warns);
    var parsed: std.ArrayListUnmanaged(sdc.commands.Parsed) = .empty;
    for (cmds) |c| try parsed.append(sdc_arena.allocator(), try sdc.commands.parse(sdc_arena.allocator(), c, &warns));
    var sdc_mod = try sdc.model.build(std.testing.allocator, parsed.items);
    defer sdc_mod.deinit();
    var awarns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    var clock_asg = try clock.trace.assign(std.testing.allocator, &mod, &sdc_mod, &awarns);
    defer clock_asg.deinit();
    var xrep = try crossing.enumerate.enumerate(std.testing.allocator, &mod, &clock_asg, &sdc_mod);
    defer xrep.deinit();

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try report.toon.writeCrossingsToon(std.testing.allocator, &aw.writer, &mod, &xrep);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try decode(arena.allocator(), aw.written());
    try std.testing.expectEqual(@as(usize, 13), doc.fields.len);
    try std.testing.expectEqual(xrep.crossings.len, doc.rows.len);
    for (xrep.crossings, 0..) |x, i| {
        try std.testing.expectEqualStrings(x.id, doc.rows[i][0].string);
        try std.testing.expectEqualStrings(@tagName(x.kind), doc.rows[i][1].string);
        try std.testing.expect(doc.rows[i][10].bool == x.async_per_sdc);
    }
    _ = sync;
}
