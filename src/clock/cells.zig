const std = @import("std");

// Sequential cell types from `proc` on the pinned Yosys: every one
// carries its clock on CLK. New shapes are table rows, not code.
const sequential = std.StaticStringMap(void).initComptime(.{
    .{ "$dff", {} },
    .{ "$dffe", {} },
    .{ "$sdff", {} },
    .{ "$sdffe", {} },
    .{ "$adff", {} },
    .{ "$adffe", {} },
    .{ "$dffsr", {} },
    .{ "$dlatch", {} },
    .{ "$dlatchsr", {} },
    .{ "$sr", {} },
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

// Clock-path structure with dedicated handling: muxes select
// between clock legs, gates AND enables onto one clock leg.
const clock_mux = std.StaticStringMap(void).initComptime(.{
    .{ "$mux", {} },
});

pub fn isClockMux(cell_type: []const u8) bool {
    return clock_mux.get(cell_type) != null;
}

const clock_gate = std.StaticStringMap(void).initComptime(.{
    .{ "$and", {} },
});

pub fn isClockGate(cell_type: []const u8) bool {
    return clock_gate.get(cell_type) != null;
}
