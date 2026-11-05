const std = @import("std");

// Sequential cell types from `proc` on the pinned Yosys: every one
// carries its clock on CLK. New shapes are table rows, not code.
const sequential = std.StaticStringMap(void).initComptime(.{
    .{ "$dff", {} },
    .{ "$dffe", {} },
    .{ "$sdff", {} },
    .{ "$sdffe", {} },
    .{ "$adff", {} },
    .{ "$dffsr", {} },
    .{ "$dlatch", {} },
});

pub fn isSequential(cell_type: []const u8) bool {
    return sequential.get(cell_type) != null;
}

// Transparent on clock paths: the domain passes through unchanged.
const transparent = std.StaticStringMap(void).initComptime(.{
    .{ "$not", {} },
});

pub fn isTransparent(cell_type: []const u8) bool {
    return transparent.get(cell_type) != null;
}

pub const clk_pin = "CLK";
