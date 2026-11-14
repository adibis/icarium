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
    \\      }
    \\    }
    \\  }
    \\}
;

fn render(mod: *const ir.types.Module, fs: []rule.finding.Finding) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try report.text.writeText(std.testing.allocator, &aw.writer, mod, fs, 0);
    return std.testing.allocator.dupe(u8, aw.written());
}

test "grouped text buckets by instance" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    var fs = [_]rule.finding.Finding{
        .{ .rule = "CDC-001", .severity = .err, .dst = "u_blk.$procdff$1", .driver = "$procdff$2", .message = "m1" },
        .{ .rule = "CDC-001", .severity = .err, .dst = "$procdff$2", .message = "m2" },
    };
    const out = try render(&mod, &fs);
    defer std.testing.allocator.free(out);
    const want =
        \\CDC-001 [error] Unsynchronized control crossing (2 findings)
        \\  [top]
        \\    $procdff$2: m2
        \\  u_blk
        \\    u_blk.$procdff$1 @ top.sv:10.3-10.20 <- $procdff$2: m1
        \\
    ;
    try std.testing.expectEqualStrings(want, out);
}

test "grouped text orders buckets first-seen, members sorted" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    var fs = [_]rule.finding.Finding{
        .{ .rule = "CDC-001", .severity = .err, .dst = "u_blk.$procdff$1", .message = "m3" },
        .{ .rule = "CDC-001", .severity = .err, .dst = "$procdff$2", .message = "m2" },
        .{ .rule = "CDC-001", .severity = .err, .dst = "u_blk.$procdff$1", .driver = "$procdff$2", .message = "m1" },
    };
    const out = try render(&mod, &fs);
    defer std.testing.allocator.free(out);
    const want =
        \\CDC-001 [error] Unsynchronized control crossing (3 findings)
        \\  [top]
        \\    $procdff$2: m2
        \\  u_blk
        \\    u_blk.$procdff$1 @ top.sv:10.3-10.20: m3
        \\    u_blk.$procdff$1 @ top.sv:10.3-10.20 <- $procdff$2: m1
        \\
    ;
    try std.testing.expectEqualStrings(want, out);
}

test "grouped text collapses single-bucket groups" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    var fs = [_]rule.finding.Finding{
        .{ .rule = "RDC-006", .severity = .warn, .dst = "$procdff$2", .driver = "d", .message = "m3" },
    };
    const out = try render(&mod, &fs);
    defer std.testing.allocator.free(out);
    const want =
        \\RDC-006 [warning] Muxed async reset without a local synchronizer (1 finding)
        \\  $procdff$2 <- d: m3
        \\
    ;
    try std.testing.expectEqualStrings(want, out);
}

test "grouped text stays silent when clean" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    const out = try render(&mod, &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}
