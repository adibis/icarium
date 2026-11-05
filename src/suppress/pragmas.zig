const std = @import("std");
const common = @import("../report.zig").common;
const ir = @import("../ir.zig");
const rule = @import("../rule.zig");
const sarif = @import("../report.zig").sarif;

pub const Region = struct {
    rule: []const u8,
    start_line: u32,
    end_line: ?u32,
    reason: []const u8,
    origin: []const u8,
};

// One pragma per line, `//` or `/*` flavored, anywhere on the
// line: `icarium: disable-rule RULE[,RULE] [free reason]`. The
// rule list takes `*`; the reason runs to end of line minus a
// block-comment terminator. Pure text scan, never elaborated.
pub fn scanText(alloc: std.mem.Allocator, text: []const u8, origin: []const u8) error{OutOfMemory}![]Region {
    var open = std.StringHashMapUnmanaged(Open).empty;
    var out = std.ArrayListUnmanaged(Region).empty;
    var lineno: u32 = 1;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| : (lineno += 1) {
        const p = parseLine(alloc, line) orelse continue;
        for (p.rules) |r| {
            if (open.fetchRemove(r)) |old| {
                try out.append(alloc, .{
                    .rule = old.key,
                    .start_line = old.value.start,
                    .end_line = lineno,
                    .reason = old.value.reason,
                    .origin = origin,
                });
            }
            if (p.disabling) try open.put(alloc, r, .{ .start = lineno, .reason = p.reason });
        }
    }
    var oit = open.iterator();
    while (oit.next()) |e| {
        try out.append(alloc, .{
            .rule = e.key_ptr.*,
            .start_line = e.value_ptr.start,
            .end_line = null,
            .reason = e.value_ptr.reason,
            .origin = origin,
        });
    }
    std.mem.sort(Region, out.items, {}, struct {
        fn less(_: void, a: Region, b: Region) bool {
            if (a.start_line != b.start_line) return a.start_line < b.start_line;
            return std.mem.order(u8, a.rule, b.rule) == .lt;
        }
    }.less);
    return out.toOwnedSlice(alloc);
}

const Open = struct { start: u32, reason: []const u8 };

const Parsed = struct {
    disabling: bool,
    rules: [][]const u8,
    reason: []const u8,
};

// First comment marker that parses wins: pragmas trail code
// as often as they stand alone, so the scan is a search, not
// an anchor. Malformed markers fall through to later ones.
fn parseLine(alloc: std.mem.Allocator, line: []const u8) ?Parsed {
    var i: usize = 0;
    while (i + 1 < line.len) : (i += 1) {
        const is_line = line[i] == '/' and line[i + 1] == '/';
        const is_block = line[i] == '/' and line[i + 1] == '*';
        if (!is_line and !is_block) continue;
        if (parseAt(alloc, line[i + 2 ..])) |p| return p;
    }
    return null;
}

fn parseAt(alloc: std.mem.Allocator, rest: []const u8) ?Parsed {
    var s = skipSpaces(rest);
    if (!std.mem.startsWith(u8, s, "icarium:")) return null;
    s = skipSpaces(s["icarium:".len..]);
    var disabling: bool = undefined;
    if (std.mem.startsWith(u8, s, "disable-rule") and boundary(s["disable-rule".len..])) {
        disabling = true;
        s = s["disable-rule".len..];
    } else if (std.mem.startsWith(u8, s, "enable-rule") and boundary(s["enable-rule".len..])) {
        disabling = false;
        s = s["enable-rule".len..];
    } else {
        return null;
    }
    s = skipSpaces(s);
    var rules = std.ArrayListUnmanaged([]const u8).empty;
    while (true) {
        const tok = takeRule(s) orelse return null;
        rules.append(alloc, tok) catch return null;
        s = skipSpaces(s[tok.len..]);
        if (s.len > 0 and s[0] == ',') {
            s = skipSpaces(s[1..]);
            continue;
        }
        break;
    }
    if (rules.items.len == 0) return null;
    return .{ .disabling = disabling, .rules = rules.items, .reason = cleanReason(s) };
}

fn boundary(s: []const u8) bool {
    return s.len == 0 or s[0] == ' ' or s[0] == '\t';
}

fn skipSpaces(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r')) i += 1;
    return s[i..];
}

fn takeRule(s: []const u8) ?[]const u8 {
    if (s.len > 0 and s[0] == '*') return s[0..1];
    var i: usize = 0;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '-')) i += 1;
    if (i == 0) return null;
    return s[0..i];
}

fn cleanReason(s: []const u8) []const u8 {
    var r = std.mem.trim(u8, s, " \t\r");
    if (std.mem.endsWith(u8, r, "*/")) r = std.mem.trim(u8, r[0 .. r.len - 2], " \t\r");
    return r;
}

pub const FileRegions = struct {
    origin: []const u8,
    regions: []Region,
};

pub const Scanned = struct {
    files: []FileRegions,
    missing: [][]const u8,
    unknown_rules: []UnknownRule,
};

pub const UnknownRule = struct {
    origin: []const u8,
    line: u32,
    rule: []const u8,
};

// Read each source once and scan it. Missing files and unknown
// rule ids report as data, never errors: a typo must warn,
// not misattribute or fail the run.
pub fn scanFiles(
    alloc: std.mem.Allocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    paths: []const []const u8,
) error{OutOfMemory}!Scanned {
    var files = std.ArrayListUnmanaged(FileRegions).empty;
    var missing = std.ArrayListUnmanaged([]const u8).empty;
    var unknown = std.ArrayListUnmanaged(UnknownRule).empty;
    for (paths) |p| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 26)) catch {
            try missing.append(alloc, p);
            continue;
        };
        defer gpa.free(bytes);
        // Regions borrow the text; the bytes free below, so the
        // scan runs over an arena-owned copy instead.
        const owned = try alloc.dupe(u8, bytes);
        const regions = try scanText(alloc, owned, p);
        var kept = std.ArrayListUnmanaged(Region).empty;
        for (regions) |r| {
            if (std.mem.eql(u8, r.rule, "*") or rule.registry.find(r.rule) != null) {
                try kept.append(alloc, r);
            } else {
                try unknown.append(alloc, .{ .origin = p, .line = r.start_line, .rule = r.rule });
            }
        }
        try files.append(alloc, .{ .origin = p, .regions = try kept.toOwnedSlice(alloc) });
    }
    return .{
        .files = try files.toOwnedSlice(alloc),
        .missing = try missing.toOwnedSlice(alloc),
        .unknown_rules = try unknown.toOwnedSlice(alloc),
    };
}

// Fill waiver hits where file waivers left none: a finding is
// excused when its dst src lands in a region for its rule. The
// region is half-open [disable, enable), so the enable line
// itself never suppresses; unclosed regions run to EOF.
pub fn apply(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    findings: []rule.finding.Finding,
    scanned: *const Scanned,
) error{OutOfMemory}!void {
    if (scanned.files.len == 0) return;
    const idx = try common.Index.build(alloc, mod);
    for (findings) |*f| {
        if (f.waiver != null) continue;
        const loc = (try dstSrc(alloc, mod, &idx, f.dst)) orelse continue;
        for (scanned.files) |fr| {
            if (!std.mem.eql(u8, fr.origin, loc.file)) continue;
            for (fr.regions) |r| {
                if (!std.mem.eql(u8, r.rule, "*") and !std.mem.eql(u8, r.rule, f.rule)) continue;
                if (loc.line < r.start_line) continue;
                if (r.end_line) |e| {
                    if (loc.line >= e) continue;
                }
                f.waiver = .{
                    .id = "pragma",
                    .reason = r.reason,
                    .location = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ r.origin, r.start_line }),
                };
                break;
            }
            if (f.waiver != null) break;
        }
    }
}

const DstSrc = struct { file: []const u8, line: u32 };

fn dstSrc(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    idx: *const common.Index,
    dst: []const u8,
) error{OutOfMemory}!?DstSrc {
    const r = try common.resolve(alloc, mod, idx, dst);
    const s = r.src orelse return null;
    const p = sarif.parseSrc(s);
    const rg = p.region orelse return null;
    if (rg.start_line <= 0 or rg.start_line > std.math.maxInt(u32)) return null;
    return .{ .file = p.uri, .line = @intCast(rg.start_line) };
}

// Distinct dst source files across the findings: pragma IO
// stays proportional to files touched, not findings.
pub fn pragmaFiles(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    findings: []rule.finding.Finding,
) error{OutOfMemory}![][]const u8 {
    const idx = try common.Index.build(alloc, mod);
    var seen = std.StringHashMapUnmanaged(void).empty;
    var out = std.ArrayListUnmanaged([]const u8).empty;
    for (findings) |f| {
        const loc = try dstSrc(alloc, mod, &idx, f.dst) orelse continue;
        if (seen.contains(loc.file)) continue;
        try seen.put(alloc, loc.file, {});
        try out.append(alloc, loc.file);
    }
    return out.toOwnedSlice(alloc);
}
