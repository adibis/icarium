const std = @import("std");
const ir = @import("icarium").ir;

const design =
    \\{"modules": {"top": {
    \\  "ports": {"clk": {"direction": "input", "bits": [2]}},
    \\  "cells": {
    \\    "a.$d1": {
    \\      "type": "$dff",
    \\      "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\      "connections": {"CLK": [2], "D": [3], "Q": [4]},
    \\      "parameters": {},
    \\      "attributes": {"src": "a.sv:1"}
    \\    },
    \\    "b.$d2": {
    \\      "type": "$dff",
    \\      "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\      "connections": {"CLK": [2], "D": [4], "Q": [5]},
    \\      "parameters": {},
    \\      "attributes": {}
    \\    },
    \\    "$m": {
    \\      "type": "$mux",
    \\      "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\      "connections": {"A": [5], "B": ["x"], "S": ["1"], "Y": [6]},
    \\      "parameters": {},
    \\      "attributes": {"src": "m.sv:9"}
    \\    }
    \\  }
    \\}}}
;

test "summary counts cells, bits, and src coverage" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, design, null);
    defer mod.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sum = try ir.stats.summarize(arena.allocator(), &mod);
    try std.testing.expectEqual(@as(usize, 3), sum.cells);
    try std.testing.expectEqual(@as(usize, 5), sum.unique_bits);
    try std.testing.expectEqual(@as(usize, 2), sum.with_src);
}

test "histogram is name-sorted and complete" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, design, null);
    defer mod.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const hist = try ir.stats.histogram(arena.allocator(), &mod);
    try std.testing.expectEqual(@as(usize, 2), hist.len);
    try std.testing.expectEqualStrings("$dff", hist[0].name);
    try std.testing.expectEqual(@as(usize, 2), hist[0].count);
    try std.testing.expectEqualStrings("$mux", hist[1].name);
    try std.testing.expectEqual(@as(usize, 1), hist[1].count);
}
