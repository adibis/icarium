const std = @import("std");
const tokens = @import("tokens.zig");

pub const CreateClock = struct {
    name: []const u8,
    period: ?f64,
    objects: [][]const u8,
};

pub const GeneratedClock = struct {
    name: []const u8,
    master: []const u8,
    divide_by: u32,
    multiply_by: u32,
    objects: [][]const u8,
};

pub const GroupKind = enum { async, logically_exclusive, physically_exclusive };

pub const ClockGroups = struct {
    kind: GroupKind,
    groups: [][][]const u8,
};

pub const FalsePath = struct {
    from: [][]const u8,
    to: [][]const u8,
    through: [][]const u8,
};

pub const PinDelay = struct {
    clock: []const u8,
    objects: [][]const u8,
};

pub const Parsed = union(enum) {
    create_clock: CreateClock,
    generated_clock: GeneratedClock,
    clock_groups: ClockGroups,
    false_path: FalsePath,
    input_delay: PinDelay,
    output_delay: PinDelay,
    unsupported: []const u8,
    skipped: []const u8,
};

// Per-line problems warn and skip; only forbidden commands abort,
// since half-processing dangerous input is worse than stopping.
pub fn parse(
    alloc: std.mem.Allocator,
    cmd: tokens.Command,
    warnings: *std.ArrayListUnmanaged(tokens.Warning),
) !Parsed {
    const name = cmd.words[0];
    if (isForbidden(name)) return error.ForbiddenCommand;
    if (std.mem.eql(u8, name, "create_clock")) return parseCreateClock(alloc, cmd, warnings);
    if (std.mem.eql(u8, name, "create_generated_clock")) return parseGeneratedClock(alloc, cmd, warnings);
    if (std.mem.eql(u8, name, "set_clock_groups")) return parseClockGroups(alloc, cmd, warnings);
    if (std.mem.eql(u8, name, "set_false_path")) return parseFalsePath(alloc, cmd, warnings);
    if (std.mem.eql(u8, name, "set_input_delay")) return parsePinDelay(alloc, cmd, warnings, true);
    if (std.mem.eql(u8, name, "set_output_delay")) return parsePinDelay(alloc, cmd, warnings, false);
    try warn(alloc, warnings, cmd.line, "unsupported command ignored");
    return .{ .unsupported = name };
}

fn isForbidden(name: []const u8) bool {
    for ([_][]const u8{ "source", "exec", "open", "load", "file", "socket" }) |f| {
        if (std.mem.eql(u8, name, f)) return true;
    }
    return false;
}

fn warn(alloc: std.mem.Allocator, warnings: *std.ArrayListUnmanaged(tokens.Warning), line: usize, text: []const u8) !void {
    try warnings.append(alloc, .{ .line = line, .text = try alloc.dupe(u8, text) });
}

fn parseCreateClock(alloc: std.mem.Allocator, cmd: tokens.Command, warnings: *std.ArrayListUnmanaged(tokens.Warning)) !Parsed {
    var name: ?[]const u8 = null;
    var period: ?f64 = null;
    var objects: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 1;
    while (i < cmd.words.len) {
        const w = cmd.words[i];
        if (std.mem.eql(u8, w, "-name") and i + 1 < cmd.words.len) {
            name = cmd.words[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, w, "-period") and i + 1 < cmd.words.len) {
            period = std.fmt.parseFloat(f64, cmd.words[i + 1]) catch {
                try warn(alloc, warnings, cmd.line, "bad period, clock skipped");
                return .{ .skipped = "create_clock" };
            };
            i += 2;
        } else if (std.mem.eql(u8, w, "-add") or std.mem.eql(u8, w, "-waveform")) {
            try warn(alloc, warnings, cmd.line, "flag accepted but not modeled");
            i += if (std.mem.eql(u8, w, "-waveform")) 2 else 1;
        } else if (w.len > 0 and w[0] == '-') {
            try warn(alloc, warnings, cmd.line, "unknown flag ignored");
            i += 1;
        } else {
            try objects.append(alloc, w);
            i += 1;
        }
    }
    if (name == null) {
        try warn(alloc, warnings, cmd.line, "create_clock without -name skipped");
        return .{ .skipped = "create_clock" };
    }
    return .{ .create_clock = .{ .name = name.?, .period = period, .objects = try objects.toOwnedSlice(alloc) } };
}

fn parseGeneratedClock(alloc: std.mem.Allocator, cmd: tokens.Command, warnings: *std.ArrayListUnmanaged(tokens.Warning)) !Parsed {
    var name: ?[]const u8 = null;
    var master: ?[]const u8 = null;
    var divide_by: u32 = 1;
    var multiply_by: u32 = 1;
    var objects: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 1;
    while (i < cmd.words.len) {
        const w = cmd.words[i];
        if (std.mem.eql(u8, w, "-name") and i + 1 < cmd.words.len) {
            name = cmd.words[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, w, "-source") and i + 1 < cmd.words.len) {
            if (master != null) try warn(alloc, warnings, cmd.line, "multiple -source, first kept");
            if (master == null) master = cmd.words[i + 1];
            i += 2;
        } else if ((std.mem.eql(u8, w, "-divide_by") or std.mem.eql(u8, w, "-multiply_by")) and i + 1 < cmd.words.len) {
            const n = std.fmt.parseInt(u32, cmd.words[i + 1], 10) catch {
                try warn(alloc, warnings, cmd.line, "bad ratio, clock skipped");
                return .{ .skipped = "create_generated_clock" };
            };
            if (std.mem.eql(u8, w, "-divide_by")) divide_by = n else multiply_by = n;
            i += 2;
        } else if (w.len > 0 and w[0] == '-') {
            try warn(alloc, warnings, cmd.line, "unknown flag ignored");
            i += 1;
        } else {
            try objects.append(alloc, w);
            i += 1;
        }
    }
    if (name == null or master == null) {
        try warn(alloc, warnings, cmd.line, "generated clock without -name/-source skipped");
        return .{ .skipped = "create_generated_clock" };
    }
    return .{ .generated_clock = .{
        .name = name.?,
        .master = master.?,
        .divide_by = divide_by,
        .multiply_by = multiply_by,
        .objects = try objects.toOwnedSlice(alloc),
    } };
}

fn parseClockGroups(alloc: std.mem.Allocator, cmd: tokens.Command, warnings: *std.ArrayListUnmanaged(tokens.Warning)) !Parsed {
    var kind: ?GroupKind = null;
    var groups: std.ArrayListUnmanaged([][]const u8) = .empty;
    var i: usize = 1;
    while (i < cmd.words.len) {
        const w = cmd.words[i];
        if (std.mem.eql(u8, w, "-asynchronous")) {
            kind = .async;
            i += 1;
        } else if (std.mem.eql(u8, w, "-logically_exclusive")) {
            kind = .logically_exclusive;
            i += 1;
        } else if (std.mem.eql(u8, w, "-physically_exclusive")) {
            kind = .physically_exclusive;
            i += 1;
        } else if (std.mem.eql(u8, w, "-group") and i + 1 < cmd.words.len) {
            var members: std.ArrayListUnmanaged([]const u8) = .empty;
            var it = std.mem.tokenizeScalar(u8, cmd.words[i + 1], ' ');
            while (it.next()) |m| try members.append(alloc, m);
            try groups.append(alloc, try members.toOwnedSlice(alloc));
            i += 2;
        } else if (w.len > 0 and w[0] == '-') {
            try warn(alloc, warnings, cmd.line, "unknown flag ignored");
            i += 1;
        } else {
            try warn(alloc, warnings, cmd.line, "stray word ignored");
            i += 1;
        }
    }
    if (kind == null) {
        try warn(alloc, warnings, cmd.line, "clock groups without relation skipped");
        return .{ .skipped = "set_clock_groups" };
    }
    return .{ .clock_groups = .{ .kind = kind.?, .groups = try groups.toOwnedSlice(alloc) } };
}

fn parseFalsePath(alloc: std.mem.Allocator, cmd: tokens.Command, warnings: *std.ArrayListUnmanaged(tokens.Warning)) !Parsed {
    var from: std.ArrayListUnmanaged([]const u8) = .empty;
    var to: std.ArrayListUnmanaged([]const u8) = .empty;
    var through: std.ArrayListUnmanaged([]const u8) = .empty;
    var current: ?*std.ArrayListUnmanaged([]const u8) = null;
    var i: usize = 1;
    while (i < cmd.words.len) {
        const w = cmd.words[i];
        if (std.mem.eql(u8, w, "-from")) {
            current = &from;
            i += 1;
        } else if (std.mem.eql(u8, w, "-to")) {
            current = &to;
            i += 1;
        } else if (std.mem.eql(u8, w, "-through")) {
            current = &through;
            i += 1;
        } else if (w.len > 0 and w[0] == '-') {
            try warn(alloc, warnings, cmd.line, "qualifier ignored");
            current = null;
            i += 1;
        } else if (current) |list| {
            var it = std.mem.tokenizeScalar(u8, w, ' ');
            while (it.next()) |m| try list.append(alloc, m);
            i += 1;
        } else {
            try warn(alloc, warnings, cmd.line, "stray word ignored");
            i += 1;
        }
    }
    if (from.items.len == 0 and to.items.len == 0 and through.items.len == 0) {
        try warn(alloc, warnings, cmd.line, "empty false path skipped");
        return .{ .skipped = "set_false_path" };
    }
    return .{ .false_path = .{
        .from = try from.toOwnedSlice(alloc),
        .to = try to.toOwnedSlice(alloc),
        .through = try through.toOwnedSlice(alloc),
    } };
}

fn parsePinDelay(
    alloc: std.mem.Allocator,
    cmd: tokens.Command,
    warnings: *std.ArrayListUnmanaged(tokens.Warning),
    comptime is_input: bool,
) !Parsed {
    const tag = if (is_input) "set_input_delay" else "set_output_delay";
    var clock: ?[]const u8 = null;
    var objects: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 1;
    if (i < cmd.words.len and isDelayValue(cmd.words[i])) i += 1;
    while (i < cmd.words.len) {
        const w = cmd.words[i];
        if (std.mem.eql(u8, w, "-clock") and i + 1 < cmd.words.len) {
            clock = cmd.words[i + 1];
            i += 2;
        } else if (w.len > 0 and w[0] == '-') {
            try warn(alloc, warnings, cmd.line, "qualifier ignored");
            // These two take values; anything else bare. A skipped
            // value would otherwise land in the port list.
            if ((std.mem.eql(u8, w, "-add_delay") or std.mem.eql(u8, w, "-reference_pin")) and i + 1 < cmd.words.len) {
                i += 2;
            } else {
                i += 1;
            }
        } else {
            try objects.append(alloc, w);
            i += 1;
        }
    }
    if (clock == null or objects.items.len == 0) {
        try warn(alloc, warnings, cmd.line, "pin delay without -clock/objects skipped");
        return .{ .skipped = tag };
    }
    const delay = PinDelay{ .clock = clock.?, .objects = try objects.toOwnedSlice(alloc) };
    if (is_input) return .{ .input_delay = delay };
    return .{ .output_delay = delay };
}

// The leading delay value precedes flags; anything else starting
// with `-` after it is a qualifier, never a negative number here.
fn isDelayValue(w: []const u8) bool {
    if (w.len == 0) return false;
    const c = w[0];
    return (c >= '0' and c <= '9') or c == '.';
}
