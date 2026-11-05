const std = @import("std");
const load = @import("icarium").ir.load;

const design =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "q": {"direction": "output", "bits": [6]}
    \\      },
    \\      "cells": {
    \\        "u_reg.$dff1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [5]},
    \\          "parameters": {"WIDTH": 1},
    \\          "attributes": {"src": "reg.sv:10.5-10.20"}
    \\        },
    \\        "$mux$1": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [3], "B": ["x", 7], "S": ["0"], "Y": [4]},
    \\          "parameters": {},
    \\          "attributes": {}
    \\        },
    \\        "u_mem.rd": {
    \\          "type": "$memrd",
    \\          "port_directions": {"CLK": "input", "ADDR": "input", "DATA": "output"},
    \\          "connections": {"CLK": [2], "ADDR": [8], "DATA": [9]},
    \\          "parameters": {"ABITS": 4},
    \\          "attributes": {}
    \\        },
    \\        "u_pll.gen": {
    \\          "type": "my_pll",
    \\          "port_directions": {"REF": "input", "OUT": "output"},
    \\          "connections": {"REF": [2], "OUT": [10]},
    \\          "parameters": {},
    \\          "attributes": {"src": "pll.sv:3"}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "cells, ports, and attributes load" {
    var mod = try load.loadFromSlice(std.testing.allocator, design, null);
    defer mod.deinit();
    try std.testing.expectEqualStrings("top", mod.name);
    try std.testing.expectEqual(@as(usize, 4), mod.cells.len);
    try std.testing.expectEqual(@as(usize, 2), mod.ports.len);

    try std.testing.expectEqualStrings("reg.sv:10.5-10.20", mod.cells[0].src.?);
    try std.testing.expect(mod.cells[1].src == null);
    try std.testing.expect(!mod.cells[0].blackbox);
    try std.testing.expect(mod.cells[3].blackbox);
}

test "instance paths derive from flattened names" {
    var mod = try load.loadFromSlice(std.testing.allocator, design, null);
    defer mod.deinit();
    try std.testing.expectEqual(@as(usize, 1), mod.cells[0].instance_path.len);
    try std.testing.expectEqualStrings("u_reg", mod.cells[0].instance_path[0]);
    try std.testing.expectEqual(@as(usize, 0), mod.cells[1].instance_path.len);
    try std.testing.expectEqualStrings("u_mem", mod.cells[2].instance_path[0]);
}

test "constant bits normalize" {
    var mod = try load.loadFromSlice(std.testing.allocator, design, null);
    defer mod.deinit();
    const mux = mod.cells[1];
    try std.testing.expect(mux.ports[1].bits[0] == .x);
    try std.testing.expectEqual(@as(u32, 7), mux.ports[1].bits[1].sig);
    try std.testing.expect(mux.ports[2].bits[0] == .zero);
}

test "driver and load maps index connectivity" {
    var mod = try load.loadFromSlice(std.testing.allocator, design, null);
    defer mod.deinit();
    const d5 = mod.driver_of.get(5).?;
    try std.testing.expectEqual(@as(usize, 0), d5.cell.?);
    try std.testing.expectEqualStrings("Q", d5.port);
    const d2 = mod.driver_of.get(2).?;
    try std.testing.expect(d2.cell == null);
    try std.testing.expectEqualStrings("clk", d2.port);
    try std.testing.expect(mod.driver_of.get(6) == null);

    const loads2 = mod.loads_of.get(2).?;
    try std.testing.expectEqual(@as(usize, 3), loads2.items.len);
}

test "top selection rules" {
    var mod = try load.loadFromSlice(std.testing.allocator, design, "top");
    defer mod.deinit();
    try std.testing.expectEqualStrings("top", mod.name);

    if (load.loadFromSlice(std.testing.allocator, design, "nope")) |m| {
        var mm = m;
        mm.deinit();
        return error.TestUnexpectedSuccess;
    } else |err| {
        try std.testing.expectEqual(error.MissingTop, err);
    }

    const two = "{\"modules\": {\"a\": {\"cells\": {}}, \"b\": {\"cells\": {}}}}";
    if (load.loadFromSlice(std.testing.allocator, two, null)) |m| {
        var mm = m;
        mm.deinit();
        return error.TestUnexpectedSuccess;
    } else |err| {
        try std.testing.expectEqual(error.AmbiguousTop, err);
    }
}

test "wide fanout indexes completely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var doc: std.ArrayListUnmanaged(u8) = .empty;
    try doc.appendSlice(alloc, "{\"modules\": {\"top\": {\"ports\": {\"clk\": {\"direction\": \"input\", \"bits\": [1]}}, \"cells\": {");
    var bit: u32 = 2;
    for (0..2000) |i| {
        const piece = try std.fmt.allocPrint(alloc, "\"u.r{d}\": {{\"type\": \"$dff\", \"port_directions\": {{\"CLK\": \"input\", \"D\": \"input\", \"Q\": \"output\"}}, \"connections\": {{\"CLK\": [1], \"D\": [{d}], \"Q\": [{d}]}}, \"parameters\": {{}}, \"attributes\": {{}}}}", .{ i, bit, bit + 1 });
        try doc.appendSlice(alloc, piece);
        if (i < 1999) try doc.appendSlice(alloc, ", ");
        bit += 1;
    }
    try doc.appendSlice(alloc, "}}}}");
    var mod = try load.loadFromSlice(std.testing.allocator, doc.items, null);
    defer mod.deinit();
    try std.testing.expectEqual(@as(usize, 2000), mod.cells.len);
    try std.testing.expect(mod.loads_of.get(1).?.items.len == 2000);
    try std.testing.expect(mod.driver_of.get(bit) != null);
}

// Exact bytes matter: this shape forces an arena chunk to be
// allocated after the Module takes shape, which a by-value arena
// would orphan from deinit. Deterministic for the pinned toolchain.
test "real yosys output frees post-copy chunks" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/fixtures/yosys-tiny.json",
        std.testing.allocator,
        .limited(1 << 20),
    );
    defer std.testing.allocator.free(bytes);
    var mod = try load.loadFromSlice(std.testing.allocator, bytes, null);
    defer mod.deinit();
    try std.testing.expectEqual(@as(usize, 2), mod.cells.len);
    try std.testing.expectEqualStrings("$dff", mod.cells[0].type);
}

test "malformed input fails, never half-loads" {
    if (load.loadFromSlice(std.testing.allocator, "not json", null)) |m| {
        var mm = m;
        mm.deinit();
        return error.TestUnexpectedSuccess;
    } else |_| {}
    if (load.loadFromSlice(std.testing.allocator, "{\"cells\": {}}", null)) |m| {
        var mm = m;
        mm.deinit();
        return error.TestUnexpectedSuccess;
    } else |err| {
        try std.testing.expectEqual(error.BadShape, err);
    }
}
