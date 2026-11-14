const std = @import("std");
const glob = @import("glob.zig");
const ir = @import("../ir.zig");
const report_common = @import("../report.zig").common;
const rule = @import("../rule.zig");

pub const schema_version = "1.0";

pub const Waiver = struct {
    id: []const u8,
    rules: [][]const u8,
    dst: ?[]const u8,
    driver: ?[]const u8,
    reason: []const u8,
    expires: ?[]const u8,
};

pub const Loaded = struct {
    backing: *std.heap.ArenaAllocator,
    waivers: []Waiver,

    pub fn deinit(self: *Loaded) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }
};

pub const Date = struct { year: u16, month: u8, day: u8 };

pub const LoadError = error{ OutOfMemory, BadWaivers };

// Today's civil date from the wall clock, for expiry checks.
// Tests inject dates directly; only the CLI reads the clock.
pub fn today(io: std.Io) Date {
    const now = std.Io.Clock.Timestamp.now(io, .real);
    const secs: u64 = @intCast(@divTrunc(now.raw.nanoseconds, 1_000_000_000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return .{
        .year = @intCast(yd.year),
        .month = @backingInt(md.month),
        .day = @intCast(md.day_index + 1),
    };
}

// Strict structural load: missing keys and mistyped values
// fail the run, since a half-read waiver file would waive by
// accident. Unknown keys pass, keeping old files forward
// compatible with additive schema growth.
pub fn load(parent: std.mem.Allocator, bytes: []const u8) LoadError!Loaded {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{}) catch return error.BadWaivers;
    if (parsed != .object) return error.BadWaivers;
    const root = parsed.object;
    const ver = root.get("schema_version") orelse return error.BadWaivers;
    if (ver != .string or !std.mem.eql(u8, ver.string, schema_version)) return error.BadWaivers;
    const arr = root.get("waivers") orelse return error.BadWaivers;
    if (arr != .array) return error.BadWaivers;
    var out = std.ArrayListUnmanaged(Waiver).empty;
    for (arr.array.items) |item| {
        if (item != .object) return error.BadWaivers;
        const o = item.object;
        const id = strField(o, "id") orelse return error.BadWaivers;
        const rules_v = o.get("rules") orelse return error.BadWaivers;
        if (rules_v != .array or rules_v.array.items.len == 0) return error.BadWaivers;
        var rules = std.ArrayListUnmanaged([]const u8).empty;
        for (rules_v.array.items) |r| {
            if (r != .string) return error.BadWaivers;
            try rules.append(alloc, r.string);
        }
        const reason = strField(o, "reason") orelse return error.BadWaivers;
        try out.append(alloc, .{
            .id = id,
            .rules = try rules.toOwnedSlice(alloc),
            .dst = optStr(o, "dst"),
            .driver = optStr(o, "driver"),
            .reason = reason,
            .expires = optStr(o, "expires"),
        });
    }
    const waivers = try out.toOwnedSlice(alloc);
    var ids = std.StringHashMapUnmanaged(void).empty;
    for (waivers) |w| {
        if (ids.contains(w.id)) return error.BadWaivers;
        try ids.put(alloc, w.id, {});
        if (w.expires) |e| {
            if (parseDate(e) == null) return error.BadWaivers;
        }
    }
    return .{ .backing = backing, .waivers = waivers };
}

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn optStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    if (v == .null) return null;
    if (v != .string) return null;
    return v.string;
}

pub const Applied = struct {
    // Parallel to the input findings: the hit that waived each,
    // or null where the finding stands.
    hits: []?rule.finding.WaiverHit,
    unmatched: [][]const u8,
    expired: [][]const u8,
};

// First matching waiver wins, in file order. Expired waivers
// never match; they report separately so stale intent stays
// visible instead of silently lapsing.
pub fn apply(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    findings: []rule.finding.Finding,
    loaded: *const Loaded,
    now: Date,
    source_path: []const u8,
) error{OutOfMemory}!Applied {
    const idx = try report_common.Index.build(alloc, mod);
    var hits = try alloc.alloc(?rule.finding.WaiverHit, findings.len);
    @memset(hits, null);
    var matched = try alloc.alloc(bool, loaded.waivers.len);
    @memset(matched, false);
    var expired = std.ArrayListUnmanaged([]const u8).empty;
    for (loaded.waivers, 0..) |w, wi| {
        if (w.expires) |e| {
            if (before(parseDate(e).?, now)) {
                try expired.append(alloc, w.id);
                continue;
            }
        }
        for (findings, 0..) |*f, fi| {
            if (hits[fi] != null) continue;
            if (!(try matches(alloc, mod, &idx, f, &w))) continue;
            matched[wi] = true;
            hits[fi] = .{ .id = w.id, .reason = w.reason, .location = source_path };
        }
    }
    var unmatched = std.ArrayListUnmanaged([]const u8).empty;
    for (loaded.waivers, 0..) |w, wi| {
        if (matched[wi]) continue;
        if (w.expires) |e| {
            if (before(parseDate(e).?, now)) continue;
        }
        try unmatched.append(alloc, w.id);
    }
    return .{
        .hits = hits,
        .unmatched = try unmatched.toOwnedSlice(alloc),
        .expired = try expired.toOwnedSlice(alloc),
    };
}

// Rule equality (or a `*` wildcard) plus optional endpoint
// patterns. `inst:`-prefixed patterns glob the slash-joined
// instance path; bare patterns glob the cell or port name.
fn matches(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    idx: *const report_common.Index,
    f: *const rule.finding.Finding,
    w: *const Waiver,
) error{OutOfMemory}!bool {
    var rule_hit = false;
    for (w.rules) |r| {
        if (std.mem.eql(u8, r, "*") or std.mem.eql(u8, r, f.rule)) {
            rule_hit = true;
            break;
        }
    }
    if (!rule_hit) return false;
    if (w.dst) |p| {
        if (!(try endMatches(alloc, mod, idx, f.dst, p))) return false;
    }
    if (w.driver) |p| {
        const d = f.driver orelse return false;
        if (!(try endMatches(alloc, mod, idx, d, p))) return false;
    }
    return true;
}

fn endMatches(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    idx: *const report_common.Index,
    name: []const u8,
    pattern: []const u8,
) error{OutOfMemory}!bool {
    if (std.mem.startsWith(u8, pattern, "inst:")) {
        const r = try report_common.resolve(alloc, mod, idx, name);
        return glob.match(pattern["inst:".len..], r.instance);
    }
    return glob.match(pattern, name);
}

// Strict YYYY-MM-DD: malformed dates fail the load, never
// parse as a surprise expiry (or non-expiry).
pub fn parseDate(s: []const u8) ?Date {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    return .{ .year = year, .month = month, .day = day };
}

fn before(a: Date, b: Date) bool {
    if (a.year != b.year) return a.year < b.year;
    if (a.month != b.month) return a.month < b.month;
    return a.day < b.day;
}
