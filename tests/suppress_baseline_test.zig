// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const ir = @import("icarium").ir;
const rule = @import("icarium").rule;
const suppress = @import("icarium").suppress;

const netlist =
    \\{"modules": {"top": {
    \\  "ports": {"clk": {"direction": "input", "bits": [2]}},
    \\  "cells": {
    \\    "b0": {"type": "$dff", "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\           "connections": {"CLK": [2], "D": [3], "Q": [4]}},
    \\    "$procdff$7": {"type": "$dff", "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\           "connections": {"CLK": [2], "D": [4], "Q": [5]}}
    \\  },
    \\  "netnames": {"sync_q": {"hide_name": 0, "bits": [5], "attributes": {}}}
    \\}}}
;

const prior =
    \\{
    \\  "schema_version": "1.0",
    \\  "groups": [
    \\    {
    \\      "rule": "RDC-008",
    \\      "severity": "error",
    \\      "title": "t",
    \\      "items": [
    \\        {
    \\          "dst": {"name": "b0", "kind": "cell", "instance": "", "src": null},
    \\          "driver": null,
    \\          "message": "stale deassertion edge",
    \\          "waiver": {"waiver_id": "w", "reason": "then waived", "location": null}
    \\        }
    \\      ]
    \\    }
    \\  ]
    \\}
;

test "baseline carries identical findings regardless of waiver state" {
    var base = try suppress.baseline.load(std.testing.allocator, prior);
    defer base.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fs = [_]rule.finding.Finding{
        .{ .rule = "RDC-008", .severity = .err, .dst = "b0", .message = "stale deassertion edge" },
        .{ .rule = "RDC-008", .severity = .err, .dst = "b0", .message = "stale deassertion edge (wording drifted)" },
        .{ .rule = "CDC-001", .severity = .err, .dst = "b0", .message = "stale deassertion edge" },
    };
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    const kept = try suppress.baseline.partition(arena.allocator(), &mod, &fs, &base);
    try std.testing.expectEqual(@as(usize, 2), kept);
    try std.testing.expectEqualStrings("stale deassertion edge (wording drifted)", fs[0].message);
    try std.testing.expectEqualStrings("CDC-001", fs[1].rule);
}

test "baseline load rejects non-reports" {
    try std.testing.expectError(error.BadBaseline, suppress.baseline.load(std.testing.allocator, "not json"));
    try std.testing.expectError(error.BadBaseline, suppress.baseline.load(std.testing.allocator, "{\"groups\": [{\"rule\": 7}]}"));
    const no_dst = "{\"groups\": [{\"rule\": \"RDC-008\", \"items\": [{\"message\": \"m\"}]}]}";
    try std.testing.expectError(error.BadBaseline, suppress.baseline.load(std.testing.allocator, no_dst));
}

test "baseline matches the message a report printed, and a 0.1 raw one" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    const doc =
        \\{"schema_version": "1.1", "groups": [{"rule": "CDC-001", "severity": "error", "title": "t", "items": [
        \\  {"dst": {"name": "b0"}, "driver": null, "message": "feeds sync_q.", "waiver": null},
        \\  {"dst": {"name": "b0"}, "driver": null, "message": "old feeds $procdff$7.", "waiver": null}
        \\]}]}
    ;
    var base = try suppress.baseline.load(std.testing.allocator, doc);
    defer base.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fs = [_]rule.finding.Finding{
        .{ .rule = "CDC-001", .severity = .err, .dst = "b0", .message = "feeds $procdff$7." },
        .{ .rule = "CDC-001", .severity = .err, .dst = "b0", .message = "old feeds $procdff$7." },
        .{ .rule = "CDC-001", .severity = .err, .dst = "b0", .message = "new $procdff$7" },
    };
    const kept = try suppress.baseline.partition(arena.allocator(), &mod, &fs, &base);
    try std.testing.expectEqual(@as(usize, 1), kept);
    try std.testing.expectEqualStrings("new $procdff$7", fs[0].message);
}
