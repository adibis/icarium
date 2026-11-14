const std = @import("std");
const ir = @import("icarium").ir;
const rule = @import("icarium").rule;
const suppress = @import("icarium").suppress;

test "scan tags flops behind scan_en clock and reset legs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try ir.load.loadFromSlice(arena.allocator(), netlist, null);
    const tagged = try suppress.scan.tagCells(arena.allocator(), &mod);
    try std.testing.expect(tagged.contains("gated"));
    try std.testing.expect(tagged.contains("reset_muxed"));
    try std.testing.expect(!tagged.contains("clean"));
    try std.testing.expect(!tagged.contains("downstream"));
}

test "scan apply excuses tagged receivers only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try ir.load.loadFromSlice(arena.allocator(), netlist, null);
    var fs = [_]rule.finding.Finding{
        .{ .rule = "CDC-001", .severity = .err, .dst = "gated", .message = "m1" },
        .{ .rule = "CDC-001", .severity = .err, .dst = "clean", .message = "m2" },
    };
    try suppress.scan.apply(arena.allocator(), &mod, &fs);
    try std.testing.expectEqualStrings("scan", fs[0].waiver.?.id);
    try std.testing.expect(fs[1].waiver == null);
}

test "rule honors stay inside the attribute vocabulary" {
    const vocab = [_][]const u8{
        "cdc_sync",   "cdc_static",     "cdc_handshake",        "cdc_gray",
        "reset_sync", "reset_polarity", "glitchless_clock_mux", "scan_en",
    };
    for (rule.registry.rules) |r| {
        for (r.honors) |h| {
            var known = false;
            for (vocab) |v| {
                if (std.mem.eql(u8, h, v)) {
                    known = true;
                    break;
                }
            }
            try std.testing.expect(known);
        }
    }
}

const netlist =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "scan_en": {"direction": "input", "bits": [9]},
    \\        "scan_clk": {"direction": "input", "bits": [10]},
    \\        "rst": {"direction": "input", "bits": [11]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "cgate": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [10], "S": [9], "Y": [13]}
    \\        },
    \\        "gated": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [13], "D": [3], "Q": [14]}
    \\        },
    \\        "rmux": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [11], "B": ["1"], "S": [9], "Y": [15]}
    \\        },
    \\        "reset_muxed": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0", "ARST_VALUE": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "ARST": [15], "Q": [16]}
    \\        },
    \\        "clean": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [12]}
    \\        },
    \\        "downstream": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [14], "Q": [17]}
    \\        }
    \\      },
    \\      "netnames": {
    \\        "scan_en": {"hide_name": 0, "bits": [9], "attributes": {"scan_en": "1"}}
    \\      }
    \\    }
    \\  }
    \\}
;

test "scan tags flops behind AND-OR scan-muxed clocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try ir.load.loadFromSlice(arena.allocator(), or_netlist, null);
    const tagged = try suppress.scan.tagCells(arena.allocator(), &mod);
    try std.testing.expect(tagged.contains("f_scan"));
    try std.testing.expect(!tagged.contains("f_clean"));
}

const or_netlist =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "scan_clk": {"direction": "input", "bits": [10]},
    \\        "scan_en": {"direction": "input", "bits": [9]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [12]},
    \\        "q2": {"direction": "output", "bits": [18]}
    \\      },
    \\      "cells": {
    \\        "sel_n": {
    \\          "type": "$not",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [9], "Y": [20]}
    \\        },
    \\        "and_func": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [9], "Y": [21]}
    \\        },
    \\        "and_scan": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [20], "Y": [22]}
    \\        },
    \\        "or_mux": {
    \\          "type": "$or",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [21], "B": [22], "Y": [13]}
    \\        },
    \\        "f_scan": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [13], "D": [3], "Q": [12]}
    \\        },
    \\        "f_clean": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [18]}
    \\        }
    \\      },
    \\      "netnames": {
    \\        "scan_en": {"hide_name": 0, "bits": [9], "attributes": {"scan_en": "1"}}
    \\      }
    \\    }
    \\  }
    \\}
;
