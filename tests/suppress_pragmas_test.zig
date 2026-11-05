const std = @import("std");
const ir = @import("icarium").ir;
const rule = @import("icarium").rule;
const suppress = @import("icarium").suppress;

fn scan(text: []const u8) ![]suppress.pragmas.Region {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const regions = try suppress.pragmas.scanText(arena.allocator(), text, "f.sv");
    // Regions borrow the input text, which outlives the arena.
    return std.testing.allocator.dupe(suppress.pragmas.Region, regions);
}

test "pragma regions are half-open per rule" {
    const text =
        \\// icarium: disable-rule CDC-001 first
        \\logic q;
        \\// icarium: disable-rule CDC-002, CDC-003 paired
        \\// icarium: enable-rule CDC-001
        \\logic r;
    ;
    const regions = try scan(text);
    defer std.testing.allocator.free(regions);
    try std.testing.expectEqual(@as(usize, 3), regions.len);
    try std.testing.expectEqualStrings("CDC-001", regions[0].rule);
    try std.testing.expectEqual(@as(u32, 1), regions[0].start_line);
    try std.testing.expectEqual(@as(u32, 4), regions[0].end_line.?);
    try std.testing.expectEqualStrings("first", regions[0].reason);
    try std.testing.expectEqualStrings("CDC-002", regions[1].rule);
    try std.testing.expect(regions[1].end_line == null);
    try std.testing.expectEqualStrings("paired", regions[1].reason);
    try std.testing.expectEqualStrings("CDC-003", regions[2].rule);
}

test "pragma re-disable restarts and stray enable drops" {
    const text =
        \\// icarium: enable-rule CDC-009
        \\/* icarium: disable-rule CDC-009 stale */
        \\logic q;
        \\// icarium: disable-rule CDC-009 fresh
        \\logic r;
    ;
    const regions = try scan(text);
    defer std.testing.allocator.free(regions);
    try std.testing.expectEqual(@as(usize, 2), regions.len);
    try std.testing.expectEqual(@as(u32, 2), regions[0].start_line);
    try std.testing.expectEqual(@as(u32, 4), regions[0].end_line.?);
    try std.testing.expectEqualStrings("stale", regions[0].reason);
    try std.testing.expectEqual(@as(u32, 4), regions[1].start_line);
    try std.testing.expect(regions[1].end_line == null);
    try std.testing.expectEqualStrings("fresh", regions[1].reason);
}

test "pragma needs a comment marker and a rule list" {
    const text =
        \\icarium: disable-rule CDC-001 bare code is not a pragma
        \\// icarium: disable-rule
        \\// rbcdc: disable-rule CDC-001 foreign prefix
        \\// icarium: disable-rule CDC-001 real one
    ;
    const regions = try scan(text);
    defer std.testing.allocator.free(regions);
    try std.testing.expectEqual(@as(usize, 1), regions.len);
    try std.testing.expectEqual(@as(u32, 4), regions[0].start_line);
}

const netlist =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "u1": {
    \\          "type": "$dff",
    \\          "attributes": {"src": "f.sv:2.3-2.20"},
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [12]}
    \\        },
    \\        "u2": {
    \\          "type": "$dff",
    \\          "attributes": {"src": "f.sv:6.3-6.20"},
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [12], "Q": [13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "pragma apply excuses dst lines inside regions" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fr = [_]suppress.pragmas.FileRegions{
        .{
            .origin = "f.sv",
            .regions = try suppress.pragmas.scanText(
                arena.allocator(),
                "// icarium: disable-rule CDC-001 vetted\nline\nline\n// icarium: enable-rule CDC-001\nline\nline\n",
                "f.sv",
            ),
        },
    };
    const scanned = suppress.pragmas.Scanned{
        .files = &fr,
        .missing = &.{},
        .unknown_rules = &.{},
    };
    var fs = [_]rule.finding.Finding{
        .{ .rule = "CDC-001", .severity = .err, .dst = "u1", .message = "m1" },
        .{ .rule = "CDC-001", .severity = .err, .dst = "u2", .message = "m2" },
        .{ .rule = "CDC-002", .severity = .err, .dst = "u1", .message = "m3" },
    };
    try suppress.pragmas.apply(arena.allocator(), &mod, &fs, &scanned);
    try std.testing.expectEqualStrings("pragma", fs[0].waiver.?.id);
    try std.testing.expectEqualStrings("vetted", fs[0].waiver.?.reason);
    try std.testing.expectEqualStrings("f.sv:1", fs[0].waiver.?.location.?);
    try std.testing.expect(fs[1].waiver == null);
    try std.testing.expect(fs[2].waiver == null);
}
