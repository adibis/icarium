// Gear file parser. Handles the .gear YAML-like format for pipeline definitions.
// Parses: name, version, triggers, stages (id, type, prompt), and termination fields.
// Prompt templates support {input}, {context}, and {stage_id} substitution tokens.

const std = @import("std");

pub const StageType = enum {
    llm,
    process,
    parallel_llm,
    condition,

    pub fn parse(s: []const u8) StageType {
        if (std.mem.eql(u8, s, "process")) return .process;
        if (std.mem.eql(u8, s, "parallel_llm")) return .parallel_llm;
        if (std.mem.eql(u8, s, "condition")) return .condition;
        return .llm;
    }
};

pub const Stage = struct {
    id:     []const u8,
    kind:   StageType,
    prompt: []const u8 = "",  // template: {input}, {context}, {stage_id}
};

pub const Gear = struct {
    name: []const u8,
    version: u32,
    triggers: []const []const u8,
    stages: []const Stage,
    termination_condition: []const u8,
    max_iterations: u32,
    on_max: []const u8,
    _arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Gear) void {
        self._arena.deinit();
    }
};

pub fn load(backing_ally: std.mem.Allocator, path: []const u8) !Gear {
    var arena = std.heap.ArenaAllocator.init(backing_ally);
    errdefer arena.deinit();
    const ally = arena.allocator();

    var path_z: [4096:0]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const f = std.c.fopen(&path_z, "r") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);

    var raw: [32768]u8 = undefined;
    const n = std.c.fread(raw[0..].ptr, 1, raw.len - 1, f);
    raw[n] = 0;
    const content = raw[0..n];

    var name: []const u8 = "";
    var version: u32 = 1;
    var triggers: std.ArrayListUnmanaged([]const u8) = .empty;
    var stages: std.ArrayListUnmanaged(Stage) = .empty;
    var term_cond: []const u8 = "";
    var max_iter: u32 = 10;
    var on_max: []const u8 = "return_last";

    // Active top-level section: "triggers" | "stages" | "termination" | ""
    var section: []const u8 = "";
    // Stage being assembled; flushed when the next stage list item starts.
    var cur_stage: ?Stage = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        var indent: usize = 0;
        while (indent < raw_line.len and raw_line[indent] == ' ') indent += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (indent == 0) {
            if (cur_stage) |s| { try stages.append(ally, s); cur_stage = null; }
            if (splitKV(line)) |p| {
                if (p.val.len == 0) {
                    section = try ally.dupe(u8, p.key);
                } else if (std.mem.eql(u8, p.key, "name")) {
                    name = try ally.dupe(u8, unquote(p.val));
                } else if (std.mem.eql(u8, p.key, "version")) {
                    version = std.fmt.parseInt(u32, p.val, 10) catch 1;
                }
            }
        } else if (indent == 2) {
            if (line[0] == '-') {
                const item = std.mem.trim(u8, line[1..], " \t");
                if (std.mem.eql(u8, section, "triggers")) {
                    try triggers.append(ally, try ally.dupe(u8, unquote(item)));
                } else if (std.mem.eql(u8, section, "stages")) {
                    if (cur_stage) |s| try stages.append(ally, s);
                    cur_stage = .{ .id = "", .kind = .llm };
                    if (splitKV(item)) |p| {
                        if (std.mem.eql(u8, p.key, "id"))
                            cur_stage.?.id = try ally.dupe(u8, unquote(p.val));
                        if (std.mem.eql(u8, p.key, "type"))
                            cur_stage.?.kind = StageType.parse(unquote(p.val));
                    }
                }
            } else if (splitKV(line)) |p| {
                if (std.mem.eql(u8, section, "termination")) {
                    if (std.mem.eql(u8, p.key, "condition"))
                        term_cond = try ally.dupe(u8, unquote(p.val));
                    if (std.mem.eql(u8, p.key, "max_iterations"))
                        max_iter = std.fmt.parseInt(u32, p.val, 10) catch 10;
                    if (std.mem.eql(u8, p.key, "on_max"))
                        on_max = try ally.dupe(u8, unquote(p.val));
                }
            }
        } else if (indent == 4) {
            if (cur_stage != null) {
                if (splitKV(line)) |p| {
                    if (std.mem.eql(u8, p.key, "id"))
                        cur_stage.?.id = try ally.dupe(u8, unquote(p.val));
                    if (std.mem.eql(u8, p.key, "type"))
                        cur_stage.?.kind = StageType.parse(unquote(p.val));
                    if (std.mem.eql(u8, p.key, "prompt"))
                        cur_stage.?.prompt = try ally.dupe(u8, unquote(p.val));
                }
            }
        }
    }
    if (cur_stage) |s| try stages.append(ally, s);

    return .{
        .name = name,
        .version = version,
        .triggers = try triggers.toOwnedSlice(ally),
        .stages = try stages.toOwnedSlice(ally),
        .termination_condition = term_cond,
        .max_iterations = max_iter,
        .on_max = on_max,
        ._arena = arena,
    };
}

const KV = struct { key: []const u8, val: []const u8 };
fn splitKV(line: []const u8) ?KV {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return .{
        .key = std.mem.trim(u8, line[0..colon], " \t"),
        .val = std.mem.trim(u8, line[colon + 1 ..], " \t"),
    };
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"')
        return s[1 .. s.len - 1];
    return s;
}
