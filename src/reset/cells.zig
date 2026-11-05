const std = @import("std");
const ir = @import("../ir.zig");

pub const AsyncPin = struct {
    pin: []const u8,
    polarity_param: []const u8,
};

pub const ResetPins = struct {
    async: []const AsyncPin,
    sync: []const []const u8,
};

// Async/sync reset pins by cell type, from `proc` output on the
// pinned Yosys. New shapes are table rows, not code.
const table = std.StaticStringMap(ResetPins).initComptime(.{
    .{ "$adff", ResetPins{ .async = &.{AsyncPin{ .pin = "ARST", .polarity_param = "ARST_POLARITY" }}, .sync = &.{} } },
    .{ "$adffe", ResetPins{ .async = &.{AsyncPin{ .pin = "ARST", .polarity_param = "ARST_POLARITY" }}, .sync = &.{} } },
    .{ "$aldff", ResetPins{ .async = &.{AsyncPin{ .pin = "ALOAD", .polarity_param = "ALOAD_POLARITY" }}, .sync = &.{} } },
    .{ "$aldffe", ResetPins{ .async = &.{AsyncPin{ .pin = "ALOAD", .polarity_param = "ALOAD_POLARITY" }}, .sync = &.{} } },
    .{ "$dffsre", ResetPins{ .async = &.{AsyncPin{ .pin = "CLR", .polarity_param = "CLR_POLARITY" }}, .sync = &.{} } },
    .{ "$dffsr", ResetPins{ .async = &.{ AsyncPin{ .pin = "SET", .polarity_param = "SET_POLARITY" }, AsyncPin{ .pin = "CLR", .polarity_param = "CLR_POLARITY" } }, .sync = &.{} } },
    .{ "$dlatchsr", ResetPins{ .async = &.{ AsyncPin{ .pin = "SET", .polarity_param = "SET_POLARITY" }, AsyncPin{ .pin = "CLR", .polarity_param = "CLR_POLARITY" } }, .sync = &.{} } },
    .{ "$sr", ResetPins{ .async = &.{ AsyncPin{ .pin = "SET", .polarity_param = "SET_POLARITY" }, AsyncPin{ .pin = "CLR", .polarity_param = "CLR_POLARITY" } }, .sync = &.{} } },
    .{ "$sdff", ResetPins{ .async = &.{}, .sync = &.{"SRST"} } },
    .{ "$sdffe", ResetPins{ .async = &.{}, .sync = &.{"SRST"} } },
    .{ "$sdffce", ResetPins{ .async = &.{}, .sync = &.{"SRST"} } },
});

pub fn resetPins(cell_type: []const u8) ?ResetPins {
    return table.get(cell_type);
}

// Reset-path muxes: $mux static selects are followed to the leg,
// $pmux one-hot needs value analysis and stays an origin.
const reset_mux = std.StaticStringMap(bool).initComptime(.{
    .{ "$mux", true },
    .{ "$pmux", false },
});

// One canonical async pin per cell, ARST first: SET pins never
// seed recognition or RDC reasoning, matching the reference.
pub fn canonicalAsyncPin(c: ir.types.Cell) ?AsyncPin {
    const rp = resetPins(c.type) orelse return null;
    for ([_][]const u8{ "ARST", "ALOAD", "CLR" }) |want| {
        for (rp.async) |ap| {
            if (!std.mem.eql(u8, ap.pin, want)) continue;
            for (c.ports) |p| {
                if (std.mem.eql(u8, p.name, want) and p.bits.len > 0) return ap;
            }
        }
    }
    return null;
}

pub fn muxFollowStatic(cell_type: []const u8) ?bool {
    return reset_mux.get(cell_type);
}
