// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const suppress = @import("../suppress.zig");

// import-meridian: convert a commercial set_rule_status Tcl
// file to native waivers.json through a JSON rule map. Follows
// literal `source` directives so index files convert whole.
// Exit: 0 clean, 1 unmapped rules remain, 2 bad input, 3 IO.
pub fn run(init: std.process.Init, out: anytype, err: anytype, argv: []const []const u8) u8 {
    var in_path: ?[]const u8 = null;
    var map_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--in") and i + 1 < argv.len) {
            in_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--map") and i + 1 < argv.len) {
            map_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--out") and i + 1 < argv.len) {
            out_path = argv[i + 1];
            i += 1;
        } else {
            err.print("import-meridian: bad argument: {s}\n", .{a}) catch {};
            return 2;
        }
    }
    const in_p = in_path orelse {
        err.writeAll("import-meridian: missing --in FILE\n") catch {};
        return 2;
    };
    const map_p = map_path orelse {
        err.writeAll("import-meridian: missing --map FILE\n") catch {};
        return 2;
    };
    const out_p = out_path orelse {
        err.writeAll("import-meridian: missing --out FILE\n") catch {};
        return 2;
    };
    const scratch = init.arena.allocator();

    const map_bytes = std.Io.Dir.cwd().readFileAlloc(init.io, map_p, init.gpa, .limited(1 << 26)) catch {
        err.print("import-meridian: cannot read {s}\n", .{map_p}) catch {};
        return 3;
    };
    defer init.gpa.free(map_bytes);
    var map = suppress.meridian.loadMap(scratch, map_bytes) catch {
        err.print("import-meridian: bad map file {s}\n", .{map_p}) catch {};
        return 2;
    };

    var records = std.ArrayListUnmanaged(suppress.meridian.Record).empty;
    var stack = std.ArrayListUnmanaged([]const u8).empty;
    stack.append(scratch, in_p) catch return 3;
    var seen = std.StringHashMapUnmanaged(void).empty;
    while (stack.items.len > 0) {
        const path = stack.pop().?;
        if (seen.contains(path)) continue;
        seen.put(scratch, path, {}) catch return 3;
        const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1 << 28)) catch {
            err.print("import-meridian: cannot read {s}\n", .{path}) catch {};
            return 3;
        };
        defer init.gpa.free(bytes);
        // Commands borrow the file bytes; the arena copy below
        // outlives the conversion.
        const owned = scratch.dupe(u8, bytes) catch return 3;
        var diag = suppress.meridian.Diagnostic{};
        const cmds = suppress.meridian.parseText(scratch, owned, &diag) catch {
            err.print("import-meridian: cannot parse {s}:{d}: {s}\n", .{ path, diag.line, diag.reason }) catch {};
            return 2;
        };
        for (cmds) |c| {
            switch (c) {
                .record => |r| records.append(scratch, r) catch return 3,
                .source => |s| {
                    const joined = joinSibling(scratch, path, s.path) catch return 3;
                    stack.append(scratch, joined) catch return 3;
                },
            }
        }
    }

    const converted = suppress.meridian.convert(scratch, records.items, &map) catch return 3;
    var aw = std.Io.Writer.Allocating.init(scratch);
    std.json.Stringify.value(converted.waivers, .{ .whitespace = .indent_2 }, &aw.writer) catch return 3;
    aw.writer.writeByte('\n') catch return 3;
    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_p, .data = aw.written() }) catch {
        err.print("import-meridian: cannot write {s}\n", .{out_p}) catch {};
        return 3;
    };
    if (converted.skipped > 0) {
        err.print("import-meridian: skipped {d} non-Waived entr{s}\n", .{ converted.skipped, if (converted.skipped == 1) "y" else "ies" }) catch {};
    }
    for (converted.unmapped) |u| {
        err.print("import-meridian: unmapped rule {s}\n", .{u.rule}) catch {};
    }
    const n = converted.waivers.object.get("waivers").?.array.items.len;
    out.print("wrote {d} waiver{s} to {s}\n", .{ n, if (n == 1) "" else "s", out_p }) catch return 3;
    return if (converted.unmapped.len > 0) 1 else 0;
}

// Sourced paths resolve beside the sourcing file, matching
// how waiver indexes lay out their category files.
fn joinSibling(alloc: std.mem.Allocator, from: []const u8, path: []const u8) error{OutOfMemory}![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    const dir = std.fs.path.dirname(from) orelse return path;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, path });
}
