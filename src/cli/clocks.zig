// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const sdc = @import("../sdc.zig");

pub fn run(init: std.process.Init, out: anytype, err: anytype, argv: []const []const u8) u8 {
    var sdc_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--sdc") and i + 1 < argv.len) {
            sdc_path = argv[i + 1];
            i += 1;
        } else {
            err.print("clocks: bad argument: {s}\n", .{a}) catch {};
            return 2;
        }
    }
    const path = sdc_path orelse {
        err.writeAll("clocks: missing --sdc FILE\n") catch {};
        return 2;
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1 << 26)) catch {
        err.print("clocks: cannot read {s}\n", .{path}) catch {};
        return 3;
    };
    defer init.gpa.free(bytes);

    const scratch = init.arena.allocator();
    var warnings: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    var mod = sdc.model.fromSlice(init.gpa, scratch, bytes, &warnings) catch |e| {
        if (e == error.ForbiddenCommand) {
            err.print("clocks: forbidden input, aborting: {t}\n", .{e}) catch {};
        } else {
            err.print("clocks: tokenize failed: {t}\n", .{e}) catch {};
        }
        return 3;
    };
    defer mod.deinit();

    // Sorted by name so repeated runs diff cleanly.
    var list: std.ArrayListUnmanaged(sdc.model.Clock) = .empty;
    var cit = mod.clocks.iterator();
    while (cit.next()) |entry| list.append(scratch, entry.value_ptr.*) catch return 3;
    std.mem.sort(sdc.model.Clock, list.items, {}, struct {
        fn less(_: void, a: sdc.model.Clock, b: sdc.model.Clock) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    for (list.items) |c| {
        out.print("clock {s}", .{c.name}) catch return 3;
        if (c.period) |p| out.print(" period {d}", .{p}) catch return 3;
        if (c.master) |m| out.print(" master {s} /{d}", .{ m, c.divide_by }) catch return 3;
        out.print("\n", .{}) catch return 3;
    }
    for (warnings.items) |w| out.print("warning line {d}: {s}\n", .{ w.line, w.text }) catch return 3;
    for (mod.warnings) |w| out.print("warning: {s}\n", .{w.text}) catch return 3;
    return 0;
}
