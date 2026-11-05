const std = @import("std");
const commands = @import("commands.zig");
const tokens = @import("tokens.zig");

pub const Clock = struct {
    name: []const u8,
    period: ?f64,
    master: ?[]const u8,
    divide_by: u32,
    multiply_by: u32,
};

pub const Group = struct {
    set: u32,
    kind: commands.GroupKind,
    members: [][]const u8,
};

pub const FalsePath = struct {
    from: [][]const u8,
    to: [][]const u8,
    through: [][]const u8,
};

pub const Model = struct {
    // Heap-owned, matching Module: copying a live arena orphans
    // later allocations from deinit (see ir/types.zig).
    backing: *std.heap.ArenaAllocator,
    clocks: std.StringHashMapUnmanaged(Clock),
    groups: []Group,
    false_paths: []FalsePath,
    port_clocks: std.StringHashMapUnmanaged([]const u8),
    warnings: []tokens.Warning,

    pub fn deinit(self: *Model) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }

    pub fn areAsync(self: *const Model, a: []const u8, b: []const u8) bool {
        if (std.mem.eql(u8, a, b)) return false;
        if (self.separatedByAsync(a, b)) return true;
        if (self.shareGroup(a, b)) return false;
        if (self.shareExclusiveSet(a, b)) return true;
        const ra = self.rootOf(a);
        const rb = self.rootOf(b);
        if (ra != null and rb != null and std.mem.eql(u8, ra.?, rb.?)) return false;
        // Undeclared relations default async: doubt must fire, not pass.
        return true;
    }

    fn separatedByAsync(self: *const Model, a: []const u8, b: []const u8) bool {
        for (self.groups) |ga| {
            if (ga.kind != .async or !memberHit(ga, a)) continue;
            for (self.groups) |gb| {
                if (gb.kind != .async or gb.set != ga.set) continue;
                if (memberHit(gb, b) and !memberHit(gb, a)) return true;
            }
        }
        return false;
    }

    fn shareGroup(self: *const Model, a: []const u8, b: []const u8) bool {
        for (self.groups) |g| {
            if (g.kind != .async) continue;
            if (memberHit(g, a) and memberHit(g, b)) return true;
        }
        return false;
    }

    fn shareExclusiveSet(self: *const Model, a: []const u8, b: []const u8) bool {
        for (self.groups) |ga| {
            if (ga.kind == .async or !memberHit(ga, a)) continue;
            for (self.groups) |gb| {
                if (gb.kind == .async or gb.set != ga.set) continue;
                if (memberHit(gb, b)) return true;
            }
        }
        return false;
    }

    fn rootOf(self: *const Model, name: []const u8) ?[]const u8 {
        var cur = name;
        var hops: usize = 0;
        while (hops < 32) : (hops += 1) {
            const c = self.clocks.get(cur) orelse return cur;
            if (c.master) |m| {
                cur = m;
            } else {
                return cur;
            }
        }
        return cur;
    }
};

// `*` globs only; SDC clock patterns rarely need more, and anything
// fancier can arrive quoted exactly once someone shows a real case.
pub fn matchGlob(pattern: []const u8, name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*') == null)
        return std.mem.eql(u8, pattern, name);
    var pi: usize = 0;
    var ni: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == name[ni])) {
            pi += 1;
            ni += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star = pi;
            mark = ni;
            pi += 1;
        } else if (star != null) {
            pi = star.? + 1;
            mark += 1;
            ni = mark;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

fn memberHit(g: Group, name: []const u8) bool {
    for (g.members) |m| if (matchGlob(m, name)) return true;
    return false;
}

pub fn portClock(self: *const Model, port: []const u8) ?[]const u8 {
    if (self.port_clocks.get(port)) |c| return c;
    var it = self.port_clocks.iterator();
    while (it.next()) |entry| {
        if (matchGlob(entry.key_ptr.*, port)) return entry.value_ptr.*;
    }
    return null;
}

pub fn build(parent: std.mem.Allocator, parsed: []const commands.Parsed) !Model {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();

    var clocks = std.StringHashMapUnmanaged(Clock){};
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    var fps: std.ArrayListUnmanaged(FalsePath) = .empty;
    var port_clocks = std.StringHashMapUnmanaged([]const u8){};
    var warnings: std.ArrayListUnmanaged(tokens.Warning) = .empty;
    var set_id: u32 = 0;

    for (parsed) |p| switch (p) {
        .create_clock => |c| {
            const slot = try clocks.getOrPut(alloc, c.name);
            if (!slot.found_existing) slot.key_ptr.* = try alloc.dupe(u8, c.name) else try warnings.append(alloc, .{
                .line = 0,
                .text = try alloc.dupe(u8, "clock redeclared, last kept"),
            });
            slot.value_ptr.* = .{
                .name = slot.key_ptr.*,
                .period = c.period,
                .master = null,
                .divide_by = 1,
                .multiply_by = 1,
            };
        },
        .generated_clock => |c| {
            const slot = try clocks.getOrPut(alloc, c.name);
            if (!slot.found_existing) slot.key_ptr.* = try alloc.dupe(u8, c.name) else try warnings.append(alloc, .{
                .line = 0,
                .text = try alloc.dupe(u8, "clock redeclared, last kept"),
            });
            slot.value_ptr.* = .{
                .name = slot.key_ptr.*,
                .period = null,
                .master = try alloc.dupe(u8, c.master),
                .divide_by = c.divide_by,
                .multiply_by = c.multiply_by,
            };
        },
        .clock_groups => |g| {
            if (g.kind != .async) try warnings.append(alloc, .{
                .line = 0,
                .text = try alloc.dupe(u8, "exclusive groups treated as async (v1 limitation)"),
            });
            for (g.groups) |members| {
                const duped = try alloc.alloc([]const u8, members.len);
                for (members, 0..) |m, i| duped[i] = try alloc.dupe(u8, m);
                try groups.append(alloc, .{ .set = set_id, .kind = g.kind, .members = duped });
            }
            set_id += 1;
        },
        .false_path => |f| {
            try fps.append(alloc, .{
                .from = try dupeList(alloc, f.from),
                .to = try dupeList(alloc, f.to),
                .through = try dupeList(alloc, f.through),
            });
        },
        .input_delay, .output_delay => |d| {
            for (d.objects) |o| {
                const slot = try port_clocks.getOrPut(alloc, o);
                if (!slot.found_existing) {
                    slot.key_ptr.* = try alloc.dupe(u8, o);
                    slot.value_ptr.* = try alloc.dupe(u8, d.clock);
                } else if (!std.mem.eql(u8, slot.value_ptr.*, d.clock)) {
                    // Same port typed twice is contradictory input, not
                    // a merge: last wins, loudly.
                    try warnings.append(alloc, .{
                        .line = 0,
                        .text = try alloc.dupe(u8, "port typed to two clocks, last kept"),
                    });
                    slot.value_ptr.* = try alloc.dupe(u8, d.clock);
                }
            }
        },
        .unsupported, .skipped => {},
    };

    try checkUndeclared(alloc, clocks, groups.items, &warnings);
    try checkPortClocks(alloc, clocks, port_clocks, &warnings);

    return .{
        .backing = backing,
        .clocks = clocks,
        .groups = try groups.toOwnedSlice(alloc),
        .false_paths = try fps.toOwnedSlice(alloc),
        .port_clocks = port_clocks,
        .warnings = try warnings.toOwnedSlice(alloc),
    };
}

fn reaches(clocks: std.StringHashMapUnmanaged(Clock), from: []const u8, target: []const u8) bool {
    var cur: ?[]const u8 = from;
    var hops: usize = 0;
    while (cur) |name| {
        if (std.mem.eql(u8, name, target)) return true;
        if (hops > clocks.count()) return false;
        hops += 1;
        const c = clocks.get(name) orelse return false;
        cur = c.master;
    }
    return false;
}

fn dupeList(alloc: std.mem.Allocator, in: [][]const u8) ![][]const u8 {
    const out = try alloc.alloc([]const u8, in.len);
    for (in, 0..) |s, i| out[i] = try alloc.dupe(u8, s);
    return out;
}

// Typo'd clock names would otherwise degrade silently into the
// async-by-default bucket; exact names get checked, globs cannot be.
fn checkUndeclared(
    alloc: std.mem.Allocator,
    clocks: std.StringHashMapUnmanaged(Clock),
    groups: []Group,
    warnings: *std.ArrayListUnmanaged(tokens.Warning),
) !void {
    var cit = clocks.iterator();
    while (cit.next()) |entry| {
        const c = entry.value_ptr.*;
        if (c.master) |m| {
            if (clocks.get(m) == null) {
                try warnings.append(alloc, .{
                    .line = 0,
                    .text = try std.fmt.allocPrint(alloc, "generated clock {s} names unknown master {s}", .{ c.name, m }),
                });
            } else if (reaches(clocks, m, c.name)) {
                try warnings.append(alloc, .{
                    .line = 0,
                    .text = try std.fmt.allocPrint(alloc, "master cycle involving {s}", .{c.name}),
                });
            }
        }
    }
    for (groups) |g| {
        for (g.members) |m| {
            if (std.mem.indexOfScalar(u8, m, '*') != null) continue;
            if (clocks.get(m) != null) continue;
            try warnings.append(alloc, .{
                .line = 0,
                .text = try std.fmt.allocPrint(alloc, "group names undeclared clock {s}", .{m}),
            });
        }
    }
}

fn checkPortClocks(
    alloc: std.mem.Allocator,
    clocks: std.StringHashMapUnmanaged(Clock),
    port_clocks: std.StringHashMapUnmanaged([]const u8),
    warnings: *std.ArrayListUnmanaged(tokens.Warning),
) !void {
    var it = port_clocks.iterator();
    while (it.next()) |entry| {
        if (clocks.get(entry.value_ptr.*) == null) try warnings.append(alloc, .{
            .line = 0,
            .text = try std.fmt.allocPrint(alloc, "port {s} typed to undeclared clock {s}", .{ entry.key_ptr.*, entry.value_ptr.* }),
        });
    }
}
