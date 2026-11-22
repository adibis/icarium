// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const ir = @import("icarium").ir;
const report = @import("icarium").report;
const rule = @import("icarium").rule;

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
    \\        "u_blk.$procdff$1": {
    \\          "type": "$dff",
    \\          "attributes": {"src": "top.sv:10.3-10.20"},
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [11]}
    \\        },
    \\        "$procdff$2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [11], "Q": [12]}
    \\        }
    \\      },
    \\      "netnames": {
    \\        "u_blk.state": {"hide_name": 0, "bits": [11], "attributes": {}},
    \\        "q": {"hide_name": 0, "bits": [12], "attributes": {}}
    \\      }
    \\    }
    \\  }
    \\}
;

test "findings.json golden" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    var fs = [_]rule.finding.Finding{
        .{ .rule = "CDC-001", .severity = .err, .dst = "u_blk.$procdff$1", .driver = "$procdff$2", .message = "m1" },
        .{ .rule = "RDC-006", .severity = .warn, .dst = "ghost", .driver = "d", .message = "m3" },
        .{ .rule = "CDC-001", .severity = .err, .dst = "d", .message = "m2" },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try report.findings.writeJson(std.testing.allocator, &aw.writer, &mod, &fs, &.{}, 0);
    const want = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{golden});
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, aw.written());
}

test "findings.json minified has no whitespace padding" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    var fs = [_]rule.finding.Finding{
        .{ .rule = "CDC-001", .severity = .err, .dst = "d", .message = "m2" },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try report.findings.writeJsonOptions(std.testing.allocator, &aw.writer, &mod, &fs, &.{}, 0, .{ .minify = true });
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"schema_version\":\"1.1\"") != null);
}

const golden =
    \\{
    \\  "schema_version": "1.1",
    \\  "design": {
    \\    "top": "top"
    \\  },
    \\  "summary": {
    \\    "errors": 2,
    \\    "warnings": 1,
    \\    "notes": 0,
    \\    "carried_over": 0
    \\  },
    \\  "groups": [
    \\    {
    \\      "rule": "CDC-001",
    \\      "severity": "error",
    \\      "title": "Unsynchronized control crossing",
    \\      "items": [
    \\        {
    \\          "severity": "error",
    \\          "dst": {
    \\            "name": "d",
    \\            "signal": "d",
    \\            "kind": "port",
    \\            "instance": "",
    \\            "src": null
    \\          },
    \\          "driver": null,
    \\          "message": "m2",
    \\          "waiver": null
    \\        },
    \\        {
    \\          "severity": "error",
    \\          "dst": {
    \\            "name": "u_blk.$procdff$1",
    \\            "signal": "u_blk.state",
    \\            "kind": "cell",
    \\            "instance": "u_blk",
    \\            "src": "top.sv:10.3-10.20"
    \\          },
    \\          "driver": {
    \\            "name": "$procdff$2",
    \\            "signal": "q",
    \\            "kind": "cell",
    \\            "instance": "",
    \\            "src": null
    \\          },
    \\          "message": "m1",
    \\          "waiver": null
    \\        }
    \\      ]
    \\    },
    \\    {
    \\      "rule": "RDC-006",
    \\      "severity": "warning",
    \\      "title": "Muxed async reset without a local synchronizer",
    \\      "items": [
    \\        {
    \\          "severity": "warning",
    \\          "dst": {
    \\            "name": "ghost",
    \\            "signal": "ghost",
    \\            "kind": "other",
    \\            "instance": "",
    \\            "src": null
    \\          },
    \\          "driver": {
    \\            "name": "d",
    \\            "signal": "d",
    \\            "kind": "port",
    \\            "instance": "",
    \\            "src": null
    \\          },
    \\          "message": "m3",
    \\          "waiver": null
    \\        }
    \\      ]
    \\    }
    \\  ],
    \\  "unmatched_waivers": []
    \\}
;
