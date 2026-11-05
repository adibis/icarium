const std = @import("std");
const rule = @import("../rule.zig");

// One-way Meridian CDC/RDC waiver importer: reads commercial
// `set_rule_status` Tcl into native waivers.json through a
// user-supplied rule map. Strict throughout: unknown commands,
// options, and expression shapes fail with file:line, since an
// accessory that guesses would launder intent. No default map
// ships here; the reviewed map arrives with the oracle work.
pub const Record = struct {
    rules: [][]const u8,
    status: []const u8,
    driver: ?[]const u8,
    receiver: ?[]const u8,
    comment: []const u8,
    line: u32,
};

pub const Command = union(enum) {
    record: Record,
    source: SourceDirective,
};

pub const SourceDirective = struct {
    path: []const u8,
    line: u32,
};

pub const ParseError = error{ OutOfMemory, BadTcl };

// Physical lines join on backslash continuations first (Tcl
// deletes the pair, gluing tokens exactly as written), then
// each logical line tokenizes and interprets independently.
pub fn parseText(alloc: std.mem.Allocator, text: []const u8) ParseError![]Command {
    var out = std.ArrayListUnmanaged(Command).empty;
    var pending = std.ArrayListUnmanaged(u8).empty;
    var start_line: u32 = 1;
    var lineno: u32 = 1;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| : (lineno += 1) {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.endsWith(u8, line, "\\") and !(line.len >= 2 and line[line.len - 2] == '\\')) {
            if (pending.items.len == 0) start_line = lineno;
            try pending.appendSlice(alloc, line[0 .. line.len - 1]);
            continue;
        }
        // Joined lines copy out: stored words outlive the
        // pending buffer, which the next clear memsets.
        const logical = if (pending.items.len == 0)
            line
        else blk: {
            try pending.appendSlice(alloc, line);
            break :blk try alloc.dupe(u8, pending.items);
        };
        const first = if (pending.items.len == 0) lineno else start_line;
        const groups = try tokenize(alloc, logical);
        for (groups) |words| {
            if (words.len == 0) continue;
            if (std.mem.eql(u8, words[0], "set_rule_status")) {
                try out.append(alloc, .{ .record = try parseRecord(alloc, words, first) });
            } else if (std.mem.eql(u8, words[0], "source") and words.len == 2) {
                try out.append(alloc, .{ .source = .{ .path = words[1], .line = first } });
            } else {
                return error.BadTcl;
            }
        }
        // Cleared after use: the logical line aliases this buffer,
        // and clearing memsets it.
        pending.clearRetainingCapacity();
    }
    if (pending.items.len != 0) return error.BadTcl;
    return out.toOwnedSlice(alloc);
}

// Words split on whitespace and top-level `;`, with brace and
// quote grouping. `#` comments run where a word could start.
// `$` and `[` never substitute: waivers are data, not code.
fn tokenize(alloc: std.mem.Allocator, line: []const u8) ParseError![][][]const u8 {
    var groups = std.ArrayListUnmanaged([][]const u8).empty;
    var words = std.ArrayListUnmanaged([]const u8).empty;
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;
        if (line[i] == ';') {
            i += 1;
            try groups.append(alloc, try words.toOwnedSlice(alloc));
            continue;
        }
        if (line[i] == '#') break;
        if (line[i] == '{') {
            const end = braceEnd(line, i) orelse return error.BadTcl;
            try words.append(alloc, line[i + 1 .. end]);
            i = end + 1;
            continue;
        }
        if (line[i] == '"') {
            const end = quoteEnd(line, i) orelse return error.BadTcl;
            try words.append(alloc, try unescape(alloc, line[i + 1 .. end]));
            i = end + 1;
            continue;
        }
        var j = i;
        while (j < line.len and line[j] != ' ' and line[j] != '\t' and line[j] != ';') j += 1;
        try words.append(alloc, line[i..j]);
        i = j;
    }
    try groups.append(alloc, try words.toOwnedSlice(alloc));
    return groups.toOwnedSlice(alloc);
}

fn braceEnd(line: []const u8, open: usize) ?usize {
    var depth: u32 = 0;
    var i = open;
    while (i < line.len) : (i += 1) {
        if (line[i] == '{') depth += 1;
        if (line[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn quoteEnd(line: []const u8, open: usize) ?usize {
    var i = open + 1;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '"') return i;
    }
    return null;
}

fn unescape(alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            try out.append(alloc, s[i + 1]);
            i += 2;
        } else {
            try out.append(alloc, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn parseRecord(alloc: std.mem.Allocator, words: [][]const u8, lineno: u32) ParseError!Record {
    var rule_v: ?[]const u8 = null;
    var status_v: ?[]const u8 = null;
    var expr_v: ?[]const u8 = null;
    var comment_v: []const u8 = "";
    var i: usize = 1;
    while (i < words.len) : (i += 2) {
        if (i + 1 >= words.len) return error.BadTcl;
        const opt = words[i];
        const val = words[i + 1];
        if (std.mem.eql(u8, opt, "-rule")) {
            rule_v = val;
        } else if (std.mem.eql(u8, opt, "-status")) {
            status_v = val;
        } else if (std.mem.eql(u8, opt, "-expression")) {
            expr_v = val;
        } else if (std.mem.eql(u8, opt, "-comment")) {
            comment_v = val;
        } else {
            return error.BadTcl;
        }
    }
    const rv = rule_v orelse return error.BadTcl;
    const sv = status_v orelse return error.BadTcl;
    var rules = std.ArrayListUnmanaged([]const u8).empty;
    var rit = std.mem.tokenizeAny(u8, rv, " \t");
    while (rit.next()) |r| try rules.append(alloc, r);
    if (rules.items.len == 0) return error.BadTcl;
    var driver: ?[]const u8 = null;
    var receiver: ?[]const u8 = null;
    if (expr_v) |e| {
        const conds = try parseExpression(alloc, e);
        for (conds) |c| {
            if (std.mem.eql(u8, c.field, "Driver")) {
                if (driver != null) return error.BadTcl;
                driver = c.glob;
            } else {
                if (receiver != null) return error.BadTcl;
                receiver = c.glob;
            }
        }
    }
    return .{
        .rules = try rules.toOwnedSlice(alloc),
        .status = sv,
        .driver = driver,
        .receiver = receiver,
        .comment = comment_v,
        .line = lineno,
    };
}

const Cond = struct { field: []const u8, glob: []const u8 };

// Conjunctions of `(Field =~ "glob")`: only Driver and
// ReceivingFlop exist downstream, so anything else fails the
// entry rather than converting half a condition.
fn parseExpression(alloc: std.mem.Allocator, e: []const u8) ParseError![]Cond {
    var out = std.ArrayListUnmanaged(Cond).empty;
    var depth: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < e.len) {
        if (e[i] == '(') depth += 1;
        if (e[i] == ')') {
            if (depth == 0) return error.BadTcl;
            depth -= 1;
        }
        if (depth == 0 and i + 1 < e.len and e[i] == '&' and e[i + 1] == '&') {
            try out.append(alloc, try parseCond(e[start..i]));
            i += 2;
            start = i;
            continue;
        }
        i += 1;
    }
    if (depth != 0) return error.BadTcl;
    const last = std.mem.trim(u8, e[start..], " \t");
    if (last.len == 0) return error.BadTcl;
    try out.append(alloc, try parseCond(last));
    return out.toOwnedSlice(alloc);
}

fn parseCond(s: []const u8) ParseError!Cond {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len < 2 or t[0] != '(' or t[t.len - 1] != ')') return error.BadTcl;
    const inner = std.mem.trim(u8, t[1 .. t.len - 1], " \t");
    var it = std.mem.tokenizeAny(u8, inner, " \t");
    const field = it.next() orelse return error.BadTcl;
    if (!std.mem.eql(u8, field, "Driver") and !std.mem.eql(u8, field, "ReceivingFlop")) return error.BadTcl;
    const op = it.next() orelse return error.BadTcl;
    if (!std.mem.eql(u8, op, "=~") and !std.mem.eql(u8, op, "==")) return error.BadTcl;
    const rest = std.mem.trim(u8, it.rest(), " \t");
    if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') return error.BadTcl;
    return .{ .field = field, .glob = rest[1 .. rest.len - 1] };
}

pub const MapError = error{ OutOfMemory, BadMap };

// Rule map: Meridian rule id to icarium rule ids. Mapped ids
// validate against the registry, so map typos fail the import
// instead of emitting waivers for rules that cannot fire.
pub fn loadMap(parent: std.mem.Allocator, bytes: []const u8) MapError!std.StringHashMapUnmanaged([][]const u8) {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, parent, bytes, .{}) catch return error.BadMap;
    if (parsed != .object) return error.BadMap;
    var map = std.StringHashMapUnmanaged([][]const u8).empty;
    var it = parsed.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .array or e.value_ptr.array.items.len == 0) return error.BadMap;
        var ids = std.ArrayListUnmanaged([]const u8).empty;
        for (e.value_ptr.array.items) |v| {
            if (v != .string) return error.BadMap;
            if (rule.registry.find(v.string) == null) return error.BadMap;
            try ids.append(parent, v.string);
        }
        try map.put(parent, e.key_ptr.*, try ids.toOwnedSlice(parent));
    }
    return map;
}

pub const Converted = struct {
    waivers: std.json.Value,
    unmapped: []Unmapped,
    skipped: u32,
};

pub const Unmapped = struct {
    rule: []const u8,
    line: u32,
};

// Records become native waivers in file order with sequential
// ids. Non-Waived statuses skip with a count (they excuse
// nothing); unmapped rules collect for the report.
pub fn convert(
    alloc: std.mem.Allocator,
    records: []const Record,
    map: *const std.StringHashMapUnmanaged([][]const u8),
) error{OutOfMemory}!Converted {
    var items = std.json.Array.init(alloc);
    var unmapped = std.ArrayListUnmanaged(Unmapped).empty;
    var skipped: u32 = 0;
    var seq: u32 = 0;
    for (records) |r| {
        if (!std.mem.eql(u8, r.status, "Waived")) {
            skipped += 1;
            continue;
        }
        var ids = std.ArrayListUnmanaged([]const u8).empty;
        for (r.rules) |mrule| {
            if (map.get(mrule)) |mapped| {
                for (mapped) |id| {
                    var dup = false;
                    for (ids.items) |have| {
                        if (std.mem.eql(u8, have, id)) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) try ids.append(alloc, id);
                }
            } else {
                try unmapped.append(alloc, .{ .rule = mrule, .line = r.line });
            }
        }
        if (ids.items.len == 0) continue;
        seq += 1;
        var rules_arr = std.json.Array.init(alloc);
        for (ids.items) |id| try rules_arr.append(.{ .string = id });
        const reason = try std.fmt.allocPrint(alloc, "[{s}] {s}", .{ try std.mem.join(alloc, ",", r.rules), r.comment });
        var w = std.json.ObjectMap.empty;
        try w.put(alloc, "id", .{ .string = try std.fmt.allocPrint(alloc, "meridian-{d:0>4}", .{seq}) });
        try w.put(alloc, "rules", .{ .array = rules_arr });
        if (r.receiver) |recv| {
            try w.put(alloc, "dst", .{ .string = recv });
        } else {
            try w.put(alloc, "dst", .null);
        }
        if (r.driver) |drv| {
            try w.put(alloc, "driver", .{ .string = drv });
        } else {
            try w.put(alloc, "driver", .null);
        }
        try w.put(alloc, "reason", .{ .string = reason });
        try w.put(alloc, "expires", .null);
        try items.append(.{ .object = w });
    }
    var root = std.json.ObjectMap.empty;
    try root.put(alloc, "schema_version", .{ .string = "1.0" });
    try root.put(alloc, "waivers", .{ .array = items });
    return .{
        .waivers = .{ .object = root },
        .unmapped = try unmapped.toOwnedSlice(alloc),
        .skipped = skipped,
    };
}
