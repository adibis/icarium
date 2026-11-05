const std = @import("std");
const rule = @import("../rule.zig");

// Baseline carryover: findings identical to a prior run's are
// set aside so CI fails only on new verdicts. The match key is
// rule + receiver + driver + message with waiver state
// excluded, so a finding re-firing after waiver expiry still
// matches its own baseline entry.
pub const LoadError = error{ OutOfMemory, BadBaseline };

pub const Baseline = struct {
    backing: *std.heap.ArenaAllocator,
    keys: std.StringHashMapUnmanaged(void),

    pub fn deinit(self: *Baseline) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }

    pub fn contains(self: *const Baseline, key: []const u8) bool {
        return self.keys.contains(key);
    }
};

// A prior --format json report: groups carry the rule, items
// the endpoints and message. Extra keys pass; the shape is a
// subset read, not a schema validation.
pub fn load(parent: std.mem.Allocator, bytes: []const u8) LoadError!Baseline {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{}) catch return error.BadBaseline;
    if (parsed != .object) return error.BadBaseline;
    const groups = parsed.object.get("groups") orelse return error.BadBaseline;
    if (groups != .array) return error.BadBaseline;
    var keys = std.StringHashMapUnmanaged(void).empty;
    for (groups.array.items) |g| {
        if (g != .object) return error.BadBaseline;
        const id = strField(g.object, "rule") orelse return error.BadBaseline;
        const items = g.object.get("items") orelse return error.BadBaseline;
        if (items != .array) return error.BadBaseline;
        for (items.array.items) |it| {
            if (it != .object) return error.BadBaseline;
            const dst = it.object.get("dst") orelse return error.BadBaseline;
            if (dst != .object) return error.BadBaseline;
            const dst_name = strField(dst.object, "name") orelse return error.BadBaseline;
            var driver_name: []const u8 = "";
            if (it.object.get("driver")) |d| {
                if (d == .object) driver_name = strField(d.object, "name") orelse return error.BadBaseline;
            }
            const msg = strField(it.object, "message") orelse return error.BadBaseline;
            try keys.put(alloc, try keyFor(alloc, id, dst_name, driver_name, msg), {});
        }
    }
    return .{ .backing = backing, .keys = keys };
}

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

// NUL-joined composite: equivalent to hashing the tuple, and
// readable when a carryover mismatch needs debugging.
pub fn keyFor(
    alloc: std.mem.Allocator,
    rule_id: []const u8,
    dst: []const u8,
    driver: []const u8,
    message: []const u8,
) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}\x00{s}\x00{s}\x00{s}", .{ rule_id, dst, driver, message });
}

pub fn findingKey(alloc: std.mem.Allocator, f: *const rule.finding.Finding) error{OutOfMemory}![]const u8 {
    return keyFor(alloc, f.rule, f.dst, f.driver orelse "", f.message);
}

// Stable partition preserving order: new findings keep their
// slots, carried-over compact behind. Returns the new count.
pub fn partition(
    alloc: std.mem.Allocator,
    findings: []rule.finding.Finding,
    baseline: *const Baseline,
) error{OutOfMemory}!usize {
    var kept: usize = 0;
    for (findings) |f| {
        const key = try findingKey(alloc, &f);
        if (baseline.contains(key)) continue;
        findings[kept] = f;
        kept += 1;
    }
    return kept;
}
