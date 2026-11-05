const std = @import("std");
const rule = @import("../rule.zig");

// One-way Meridian CDC/RDC waiver importer: reads commercial
// `set_rule_status` Tcl into native waivers.json through a
// user-supplied rule map. Unknown commands, options (outside GUI
// audit stamps), and expression shapes fail with file:line plus a
// reason, since an accessory that guesses would launder intent.
// Locator fields become endpoints; value fields ride the comment.
// No default map ships here; the reviewed map arrives with the
// oracle work.
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

pub const Diagnostic = struct {
    line: u32 = 0,
    reason: []const u8 = "",
};

// Physical lines join on backslash continuations first (Tcl
// deletes the pair, gluing tokens exactly as written), then
// each logical line tokenizes and interprets independently.
pub fn parseText(alloc: std.mem.Allocator, text: []const u8, diag: ?*Diagnostic) ParseError![]Command {
    if (diag) |d| d.* = .{};
    var out = std.ArrayListUnmanaged(Command).empty;
    var pending = std.ArrayListUnmanaged(u8).empty;
    var start_line: u32 = 1;
    var lineno: u32 = 1;
    var prev_cont = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| : (lineno += 1) {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const cont = std.mem.endsWith(u8, line, "\\") and !(line.len >= 2 and line[line.len - 2] == '\\');
        const frag = if (cont) line[0 .. line.len - 1] else line;
        // Backslash-newline deletes the pair; newlines inside open
        // braces or quotes join with a space, as Tcl would keep them.
        if (pending.items.len == 0) {
            start_line = lineno;
        } else if (!prev_cont) {
            try pending.append(alloc, ' ');
        }
        try pending.appendSlice(alloc, frag);
        prev_cont = cont;
        // A trailing backslash always joins, balanced or not;
        // only a plain line end consults the brace balance.
        if (cont) continue;
        switch (joinState(pending.items)) {
            .balanced => {},
            .open => continue,
            .bad => {
                if (diag) |d| d.line = start_line;
                setReason(diag, "unbalanced brace");
                return error.BadTcl;
            },
        }
        // Joined lines copy out: stored words outlive the
        // pending buffer, which the next clear memsets.
        const logical = try alloc.dupe(u8, pending.items);
        if (diag) |d| d.line = start_line;
        const groups = try tokenize(alloc, logical, diag);
        for (groups) |words| {
            if (words.len == 0) continue;
            if (std.mem.eql(u8, words[0], "set_rule_status")) {
                for (try parseRecord(alloc, words, start_line, diag)) |rec| {
                    try out.append(alloc, .{ .record = rec });
                }
            } else if (std.mem.eql(u8, words[0], "source") and words.len == 2) {
                try out.append(alloc, .{ .source = .{ .path = words[1], .line = start_line } });
            } else {
                setReason(diag, "expected set_rule_status or source");
                return error.BadTcl;
            }
        }
        // Cleared after use: the logical line aliases this buffer,
        // and clearing memsets it.
        pending.clearRetainingCapacity();
    }
    if (pending.items.len != 0) {
        if (diag) |d| d.line = start_line;
        setReason(diag, "unbalanced brace");
        return error.BadTcl;
    }
    return out.toOwnedSlice(alloc);
}

const JoinState = enum { balanced, open, bad };

// Brace balance outside quotes decides line joining: open braces
// pull the next line in, a stray closer fails the entry outright.
fn joinState(s: []const u8) JoinState {
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 2;
            continue;
        }
        // Comments end the scan: braces in prose never join lines.
        if (depth == 0 and s[i] == '#' and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t' or s[i - 1] == ';')) break;
        if (s[i] == '"' and depth == 0) {
            i = quoteSkip(s, i) orelse return .open;
            continue;
        }
        if (s[i] == '{') depth += 1;
        if (s[i] == '}') {
            if (depth == 0) return .bad;
            depth -= 1;
        }
        i += 1;
    }
    return if (depth == 0) .balanced else .open;
}

fn setReason(diag: ?*Diagnostic, reason: []const u8) void {
    if (diag) |d| d.reason = reason;
}

// Words split on whitespace and top-level `;`, with brace and
// quote grouping. `#` comments run where a word could start.
// `$` and `[` never substitute: waivers are data, not code.
fn tokenize(alloc: std.mem.Allocator, line: []const u8, diag: ?*Diagnostic) ParseError![][][]const u8 {
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
            const end = braceEnd(line, i) orelse {
                setReason(diag, "unbalanced brace");
                return error.BadTcl;
            };
            try words.append(alloc, line[i + 1 .. end]);
            i = end + 1;
            continue;
        }
        if (line[i] == '"') {
            const end = quoteEnd(line, i) orelse {
                setReason(diag, "unbalanced quote");
                return error.BadTcl;
            };
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

fn parseRecord(alloc: std.mem.Allocator, words: [][]const u8, lineno: u32, diag: ?*Diagnostic) ParseError![]Record {
    var rule_v: ?[]const u8 = null;
    var status_v: ?[]const u8 = null;
    var expr_v: ?[]const u8 = null;
    var comment_v: []const u8 = "";
    var i: usize = 1;
    while (i < words.len) : (i += 2) {
        if (i + 1 >= words.len) {
            setReason(diag, "option without a value");
            return error.BadTcl;
        }
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
        } else if (std.mem.startsWith(u8, opt, "-lastedit_")) {
            // GUI audit stamps carry no waiver intent; anything
            // else unknown still fails rather than guessing.
        } else {
            setReason(diag, "unknown set_rule_status option");
            return error.BadTcl;
        }
    }
    const rv = rule_v orelse {
        setReason(diag, "missing -rule");
        return error.BadTcl;
    };
    // A status-less entry inside a waiver file reads waived; the
    // note keeps the assumption visible instead of silent.
    const sv = status_v orelse "Waived";
    const comment_marked = if (status_v == null)
        try std.fmt.allocPrint(alloc, "{s} [no -status given]", .{comment_v})
    else
        comment_v;
    var rules = std.ArrayListUnmanaged([]const u8).empty;
    var rit = std.mem.tokenizeAny(u8, rv, " \t");
    while (rit.next()) |r| try rules.append(alloc, r);
    if (rules.items.len == 0) {
        setReason(diag, "empty -rule");
        return error.BadTcl;
    }
    const rule_list = try rules.toOwnedSlice(alloc);
    const disjuncts = if (expr_v) |e| try parseExpression(alloc, e, diag) else blk: {
        const one = try alloc.alloc(Cond, 0);
        const out = try alloc.alloc([]Cond, 1);
        out[0] = one;
        break :blk out;
    };
    var out = std.ArrayListUnmanaged(Record).empty;
    for (disjuncts) |conj| {
        var drivers = std.ArrayListUnmanaged([]const u8).empty;
        var receivers = std.ArrayListUnmanaged([]const u8).empty;
        var context = std.ArrayListUnmanaged(Cond).empty;
        for (conj) |c| {
            switch (slotFor(c.field)) {
                .driver => try drivers.append(alloc, c.glob),
                .receiver => try receivers.append(alloc, c.glob),
                .context => try context.append(alloc, c),
            }
        }
        const noted = try withContext(alloc, comment_marked, context.items);
        // One side single means cartesian pairs; two crowded
        // sides split per locator instead of exploding.
        if (drivers.items.len <= 1 or receivers.items.len <= 1) {
            const ds = if (drivers.items.len == 0) &[_][]const u8{""} else drivers.items;
            const rs = if (receivers.items.len == 0) &[_][]const u8{""} else receivers.items;
            for (ds) |d| {
                for (rs) |r| {
                    try out.append(alloc, .{
                        .rules = rule_list,
                        .status = sv,
                        .driver = if (d.len == 0) null else d,
                        .receiver = if (r.len == 0) null else r,
                        .comment = noted,
                        .line = lineno,
                    });
                }
            }
        } else {
            for (drivers.items) |d| try out.append(alloc, .{
                .rules = rule_list,
                .status = sv,
                .driver = d,
                .receiver = null,
                .comment = noted,
                .line = lineno,
            });
            for (receivers.items) |r| try out.append(alloc, .{
                .rules = rule_list,
                .status = sv,
                .driver = null,
                .receiver = r,
                .comment = noted,
                .line = lineno,
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

const Slot = enum { driver, receiver, context };

// Locator fields name waiver endpoints; value fields (clocks,
// depths, classes) ride the comment so nothing silently narrows.
fn slotFor(field: []const u8) Slot {
    const receivers = [_][]const u8{ "receivingflop", "resetsyncflop", "syncflop", "glitchoutput", "drivenflop", "samplerxsignal", "fanout" };
    for (receivers) |r| if (std.ascii.eqlIgnoreCase(field, r)) return .receiver;
    const drivers = [_][]const u8{ "driver", "resetsignal", "signal", "gatedclock", "glitchinput", "sampletxsignal", "drivingsignal" };
    for (drivers) |d| if (std.ascii.eqlIgnoreCase(field, d)) return .driver;
    return .context;
}

fn withContext(alloc: std.mem.Allocator, comment: []const u8, context: []Cond) error{OutOfMemory}![]const u8 {
    if (context.len == 0) return comment;
    var buf = std.ArrayListUnmanaged(u8).empty;
    try buf.appendSlice(alloc, comment);
    try buf.appendSlice(alloc, " [");
    for (context, 0..) |c, i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, c.field);
        try buf.appendSlice(alloc, "=\"");
        try buf.appendSlice(alloc, c.glob);
        try buf.append(alloc, '"');
    }
    try buf.append(alloc, ']');
    return buf.toOwnedSlice(alloc);
}

const Cond = struct { field: []const u8, glob: []const u8 };

// Disjunctions of conjunctions of `(Field op "glob")`: `||`
// distributes into sibling records, `&&` conjoins, groups nest
// to eight wide to sixty-four. Empty waives rule-wide.
fn parseExpression(alloc: std.mem.Allocator, e: []const u8, diag: ?*Diagnostic) ParseError![][]Cond {
    const t = std.mem.trim(u8, e, " \t");
    if (t.len == 0) {
        const one = try alloc.alloc(Cond, 0);
        const out = try alloc.alloc([]Cond, 1);
        out[0] = one;
        return out;
    }
    return parseDNF(alloc, t, 0, diag);
}

fn parseDNF(alloc: std.mem.Allocator, s: []const u8, depth: u8, diag: ?*Diagnostic) ParseError![][]Cond {
    if (depth >= 8) {
        setReason(diag, "expression nests too deep");
        return error.BadTcl;
    }
    var out = std.ArrayListUnmanaged([]Cond).empty;
    for (try splitTop(alloc, s, "||", diag)) |branch| {
        const parts = try splitTop(alloc, branch, "&&", diag);
        var acc = std.ArrayListUnmanaged([]Cond).empty;
        try acc.append(alloc, try alloc.alloc(Cond, 0));
        for (parts) |piece| {
            const pd = try parsePiece(alloc, piece, depth + 1, diag);
            var next = std.ArrayListUnmanaged([]Cond).empty;
            for (acc.items) |a| {
                for (pd) |b| {
                    const joined = try alloc.alloc(Cond, a.len + b.len);
                    @memcpy(joined[0..a.len], a);
                    @memcpy(joined[a.len..], b);
                    try next.append(alloc, joined);
                    if (next.items.len > 64) {
                        setReason(diag, "expression disjunction too wide");
                        return error.BadTcl;
                    }
                }
            }
            acc = next;
        }
        for (acc.items) |conj| {
            try out.append(alloc, conj);
            if (out.items.len > 64) {
                setReason(diag, "expression disjunction too wide");
                return error.BadTcl;
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

// A piece is one condition or a parenthesized group: the group
// recurs only when its inside carries a top-level connective.
fn parsePiece(alloc: std.mem.Allocator, s: []const u8, depth: u8, diag: ?*Diagnostic) ParseError![][]Cond {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and t[0] == '(' and matchEnd(t) == t.len - 1) {
        const inner = std.mem.trim(u8, t[1 .. t.len - 1], " \t");
        if (hasTopOp(inner)) return parseDNF(alloc, inner, depth, diag);
    }
    const one = try alloc.alloc(Cond, 1);
    one[0] = try parseCond(alloc, t, diag);
    const out = try alloc.alloc([]Cond, 1);
    out[0] = one;
    return out;
}

// Index of the paren closing the opener, quotes honored;
// unbalanced input reports past-the-end, never a false match.
fn matchEnd(s: []const u8) usize {
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 2;
            continue;
        }
        if (s[i] == '"') {
            i = quoteSkip(s, i) orelse return s.len;
            continue;
        }
        if (s[i] == '(') depth += 1;
        if (s[i] == ')') {
            if (depth == 0) return s.len;
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return s.len;
}

fn hasTopOp(s: []const u8) bool {
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 2;
            continue;
        }
        if (s[i] == '"') {
            i = quoteSkip(s, i) orelse return false;
            continue;
        }
        if (s[i] == '(') depth += 1;
        if (s[i] == ')') {
            if (depth > 0) depth -= 1;
        }
        if (depth == 0 and i + 1 < s.len) {
            if ((s[i] == '|' and s[i + 1] == '|') or (s[i] == '&' and s[i + 1] == '&')) return true;
        }
        i += 1;
    }
    return false;
}

// Splits on the connective at paren depth zero outside quotes;
// nested groups survive intact for the recursive descent.
fn splitTop(alloc: std.mem.Allocator, s: []const u8, op: *const [2]u8, diag: ?*Diagnostic) ParseError![][]const u8 {
    var out = std.ArrayListUnmanaged([]const u8).empty;
    var depth: u32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 2;
            continue;
        }
        if (s[i] == '"') {
            i = quoteSkip(s, i) orelse {
                setReason(diag, "unbalanced quote in expression");
                return error.BadTcl;
            };
            continue;
        }
        if (s[i] == '(') depth += 1;
        if (s[i] == ')') {
            if (depth == 0) {
                setReason(diag, "unbalanced paren in expression");
                return error.BadTcl;
            }
            depth -= 1;
        }
        if (depth == 0 and i + 1 < s.len and s[i] == op[0] and s[i + 1] == op[1]) {
            try out.append(alloc, std.mem.trim(u8, s[start..i], " \t"));
            i += 2;
            start = i;
            continue;
        }
        i += 1;
    }
    if (depth != 0) {
        setReason(diag, "unbalanced paren in expression");
        return error.BadTcl;
    }
    const last = std.mem.trim(u8, s[start..], " \t");
    if (last.len == 0) {
        setReason(diag, "dangling connective in expression");
        return error.BadTcl;
    }
    try out.append(alloc, last);
    return out.toOwnedSlice(alloc);
}

fn quoteSkip(s: []const u8, open: usize) ?usize {
    var i = open + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '"') return i + 1;
    }
    return null;
}

fn parseCond(alloc: std.mem.Allocator, s: []const u8, diag: ?*Diagnostic) ParseError!Cond {
    const t = std.mem.trim(u8, s, " \t");
    // Bare `Field op "glob"` without parens appears in the wild;
    // both spellings parse to the same condition.
    const inner = if (t.len >= 2 and t[0] == '(' and t[t.len - 1] == ')')
        std.mem.trim(u8, t[1 .. t.len - 1], " \t")
    else
        t;
    const split = opSplit(inner) orelse {
        setReason(diag, "condition needs == or =~");
        return error.BadTcl;
    };
    const field = std.mem.trim(u8, inner[0..split], " \t");
    if (field.len == 0 or !isFieldName(field)) {
        setReason(diag, "bad condition field");
        return error.BadTcl;
    }
    const rest = std.mem.trim(u8, inner[split + 2 ..], " \t");
    const glob = unquote(alloc, rest) catch |e| {
        if (e == error.BadTcl) setReason(diag, "condition value must be quoted");
        return e;
    };
    return .{ .field = field, .glob = glob };
}

// First == or =~ outside quotes: spaces around the operator
// stay optional, matching the waiver files as written.
fn opSplit(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 2;
            continue;
        }
        if (s[i] == '"') {
            i = quoteSkip(s, i) orelse return null;
            continue;
        }
        if (s[i] == '=' and i + 1 < s.len and (s[i + 1] == '=' or s[i + 1] == '~')) return i;
        i += 1;
    }
    return null;
}

fn isFieldName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

// Brace grouping preserves backslashes, so values arrive with
// literal \" delimiters; both spellings unwrap identically.
fn unquote(alloc: std.mem.Allocator, s: []const u8) ParseError![]const u8 {
    const inner = if (s.len >= 4 and s[0] == '\\' and s[1] == '"' and s[s.len - 2] == '\\' and s[s.len - 1] == '"')
        s[2 .. s.len - 2]
    else if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"')
        s[1 .. s.len - 1]
    else
        return error.BadTcl;
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
    var out = std.ArrayListUnmanaged(u8).empty;
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            try out.append(alloc, inner[i + 1]);
            i += 2;
        } else {
            try out.append(alloc, inner[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

pub const MapError = error{ OutOfMemory, BadMap };

// Rule map: Meridian rule id to icarium rule ids. Mapped ids
// validate against the registry, so map typos fail the import
// instead of emitting waivers for rules that cannot fire.
pub fn loadMap(parent: std.mem.Allocator, bytes: []const u8) MapError!std.StringHashMapUnmanaged([][]const u8) {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, parent, bytes, .{}) catch return error.BadMap;
    if (parsed != .object) return error.BadMap;
    // Reserved IDs are the map's own forward references: waivers may
    // name rules not yet implemented, unmatched until they land.
    var reserved = std.StringHashMapUnmanaged(void).empty;
    if (parsed.object.get("_meta")) |m| {
        if (m == .object) {
            if (m.object.get("reserved")) |r| {
                if (r == .array) {
                    for (r.array.items) |v| {
                        if (v == .string) try reserved.put(parent, v.string, {});
                    }
                }
            }
        }
    }
    var map = std.StringHashMapUnmanaged([][]const u8).empty;
    var it = parsed.object.iterator();
    while (it.next()) |e| {
        if (std.mem.startsWith(u8, e.key_ptr.*, "_")) continue;
        if (e.value_ptr.* != .array or e.value_ptr.array.items.len == 0) return error.BadMap;
        var ids = std.ArrayListUnmanaged([]const u8).empty;
        for (e.value_ptr.array.items) |v| {
            if (v != .string) return error.BadMap;
            if (rule.registry.find(v.string) == null and !reserved.contains(v.string)) return error.BadMap;
            try ids.append(parent, v.string);
        }
        try map.put(parent, e.key_ptr.*, try ids.toOwnedSlice(parent));
    }
    return map;
}

// Waiver files spell the verdict loosely; anything else
// excuses nothing, so it skips with a count, never converts.
fn isWaived(status: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, status, " \t"), "waived");
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
        if (!isWaived(r.status)) {
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
