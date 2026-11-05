const std = @import("std");

pub const Command = struct {
    line: usize,
    words: [][]const u8,
};

pub const Warning = struct {
    line: usize,
    text: []const u8,
};

// `#` starts a comment at segment start or after whitespace: SDC
// writers use trailing comments, which strict Tcl would misread.
pub fn parseCommands(
    alloc: std.mem.Allocator,
    text: []const u8,
    warnings: *std.ArrayListUnmanaged(Warning),
) ![]Command {
    var out: std.ArrayListUnmanaged(Command) = .empty;
    var line_no: usize = 1;
    var i: usize = 0;
    while (i < text.len) {
        const start_line = line_no;
        var logical: std.ArrayListUnmanaged(u8) = .empty;
        defer logical.deinit(alloc);
        while (i < text.len) {
            const c = text[i];
            if (c == '\\' and i + 1 < text.len and text[i + 1] == '\n') {
                try logical.append(alloc, ' ');
                i += 2;
                line_no += 1;
            } else if (c == '\n') {
                i += 1;
                line_no += 1;
                break;
            } else if (c == '\r') {
                i += 1;
            } else {
                try logical.append(alloc, c);
                i += 1;
            }
        }
        const stripped = stripComment(logical.items);
        var segs = try splitSegments(alloc, stripped);
        defer {
            for (segs.items) |s| alloc.free(s);
            segs.deinit(alloc);
        }
        for (segs.items) |seg| {
            const words = try tokenizeWords(alloc, seg, start_line, warnings);
            if (words.len == 0) {
                alloc.free(words);
                continue;
            }
            try out.append(alloc, .{ .line = start_line, .words = words });
        }
    }
    return out.toOwnedSlice(alloc);
}

fn stripComment(line: []const u8) []const u8 {
    var depth: usize = 0;
    var in_quote = false;
    var in_bracket = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_quote) {
            if (c == '\\') i += 1;
            if (c == '"') in_quote = false;
        } else if (c == '"') {
            in_quote = true;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -|= 1;
        } else if (c == '[') {
            in_bracket = true;
        } else if (c == ']') {
            in_bracket = false;
        } else if (c == '#' and depth == 0 and !in_bracket and (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t')) {
            return line[0..i];
        }
    }
    return line;
}

fn splitSegments(alloc: std.mem.Allocator, line: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var depth: usize = 0;
    var in_quote = false;
    var in_bracket = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_quote) {
            if (c == '\\') i += 1;
            if (c == '"') in_quote = false;
        } else if (c == '"') {
            in_quote = true;
        } else if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            depth -|= 1;
        } else if (c == '[') {
            in_bracket = true;
        } else if (c == ']') {
            in_bracket = false;
        } else if (c == ';' and depth == 0 and !in_bracket) {
            try out.append(alloc, try alloc.dupe(u8, line[start..i]));
            start = i + 1;
        }
    }
    try out.append(alloc, try alloc.dupe(u8, line[start..]));
    return out;
}

fn tokenizeWords(
    alloc: std.mem.Allocator,
    seg: []const u8,
    line: usize,
    warnings: *std.ArrayListUnmanaged(Warning),
) ![][]const u8 {
    var words: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < seg.len) {
        while (i < seg.len and (seg[i] == ' ' or seg[i] == '\t')) : (i += 1) {}
        if (i >= seg.len) break;
        var word: std.ArrayListUnmanaged(u8) = .empty;
        while (i < seg.len and seg[i] != ' ' and seg[i] != '\t') {
            const c = seg[i];
            if (c == '{') {
                const end = findClose(seg, i, '{', '}') orelse return error.UnbalancedBraces;
                try word.appendSlice(alloc, seg[i + 1 .. end]);
                i = end + 1;
            } else if (c == '"') {
                i = try appendQuoted(alloc, &word, seg, i, line, warnings);
            } else if (c == '[') {
                // Glued substitution has no sane word split; real
                // constraints never glue, so refuse instead of guessing.
                if (word.items.len > 0) return error.GluedSubstitution;
                i = try spliceSubstitution(alloc, &words, seg, i);
                if (i < seg.len and seg[i] != ' ' and seg[i] != '\t') return error.GluedSubstitution;
            } else {
                try word.append(alloc, c);
                i += 1;
            }
        }
        if (word.items.len > 0) {
            try words.append(alloc, try word.toOwnedSlice(alloc));
        } else {
            word.deinit(alloc);
        }
    }
    return words.toOwnedSlice(alloc);
}

// Substitution splices pattern words inline; only get_* readers run,
// anything else is refused rather than half-evaluated.
fn spliceSubstitution(
    alloc: std.mem.Allocator,
    words: *std.ArrayListUnmanaged([]const u8),
    seg: []const u8,
    start: usize,
) !usize {
    const end = std.mem.indexOfScalarPos(u8, seg, start + 1, ']') orelse return error.UnbalancedBracket;
    const inner = seg[start + 1 .. end];
    if (std.mem.indexOfScalar(u8, inner, '[') != null) return error.NestedSubstitution;
    var it = std.mem.tokenizeScalar(u8, inner, ' ');
    const cmd = it.next() orelse return error.EmptySubstitution;
    const allowed = std.mem.eql(u8, cmd, "get_ports") or
        std.mem.eql(u8, cmd, "get_clocks") or
        std.mem.eql(u8, cmd, "get_cells") or
        std.mem.eql(u8, cmd, "get_pins");
    if (!allowed) return error.ForbiddenSubstitution;
    while (it.next()) |w| try words.append(alloc, try alloc.dupe(u8, w));
    return end + 1;
}

fn appendQuoted(
    alloc: std.mem.Allocator,
    word: *std.ArrayListUnmanaged(u8),
    seg: []const u8,
    start: usize,
    line: usize,
    warnings: *std.ArrayListUnmanaged(Warning),
) !usize {
    var i = start + 1;
    while (i < seg.len) {
        const c = seg[i];
        if (c == '"') return i + 1;
        if (c == '\\' and i + 1 < seg.len) {
            const e = seg[i + 1];
            const mapped: ?u8 = switch (e) {
                '\\' => '\\',
                '"' => '"',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => null,
            };
            if (mapped) |m| {
                try word.append(alloc, m);
            } else {
                try word.append(alloc, c);
                try word.append(alloc, e);
                try warnings.append(alloc, .{ .line = line, .text = try alloc.dupe(u8, "unknown escape kept literal") });
            }
            i += 2;
        } else {
            try word.append(alloc, c);
            i += 1;
        }
    }
    return error.UnbalancedQuote;
}

fn findClose(seg: []const u8, start: usize, open: u8, close: u8) ?usize {
    std.debug.assert(seg[start] == open);
    var depth: usize = 0;
    var i = start;
    while (i < seg.len) : (i += 1) {
        if (seg[i] == open) depth += 1 else if (seg[i] == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}
