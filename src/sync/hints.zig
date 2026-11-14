// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const reset = @import("../reset.zig");

// External reset hints for untouchable RTL: port polarity
// declarations and synchronizer stage membership in the same
// vocabulary as the in-RTL attributes. JSON-native, mirroring
// the reference YAML vocabulary key for key; hints win on
// disagreement with attributes.
pub const Hints = struct {
    backing: *std.heap.ArenaAllocator,
    polarities: std.StringHashMapUnmanaged(reset.trace.Polarity),
    syncs: [][]const u8,

    pub fn deinit(self: *Hints) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }
};

pub const LoadError = error{ OutOfMemory, BadHints };

pub fn load(parent: std.mem.Allocator, bytes: []const u8) LoadError!Hints {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{}) catch return error.BadHints;
    if (parsed != .object) return error.BadHints;
    var polarities = std.StringHashMapUnmanaged(reset.trace.Polarity).empty;
    if (parsed.object.get("polarities")) |pv| {
        if (pv != .object) return error.BadHints;
        var it = pv.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* != .string) return error.BadHints;
            const pol: reset.trace.Polarity = if (std.mem.eql(u8, e.value_ptr.string, "high"))
                .high
            else if (std.mem.eql(u8, e.value_ptr.string, "low"))
                .low
            else
                return error.BadHints;
            try polarities.put(alloc, e.key_ptr.*, pol);
        }
    }
    var syncs = std.ArrayListUnmanaged([]const u8).empty;
    if (parsed.object.get("syncs")) |sv| {
        if (sv != .array) return error.BadHints;
        for (sv.array.items) |s| {
            if (s != .string) return error.BadHints;
            try syncs.append(alloc, s.string);
        }
    }
    return .{
        .backing = backing,
        .polarities = polarities,
        .syncs = try syncs.toOwnedSlice(alloc),
    };
}
