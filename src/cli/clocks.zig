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
    const cmds = sdc.tokens.parseCommands(scratch, bytes, &warnings) catch |e| {
        err.print("clocks: tokenize failed: {t}\n", .{e}) catch {};
        return 3;
    };
    var parsed: std.ArrayListUnmanaged(sdc.commands.Parsed) = .empty;
    for (cmds) |c| {
        parsed.append(scratch, sdc.commands.parse(scratch, c, &warnings) catch |e| {
            err.print("clocks: forbidden input, aborting: {t}\n", .{e}) catch {};
            return 3;
        }) catch return 3;
    }
    var mod = sdc.model.build(init.gpa, parsed.items) catch return 3;
    defer mod.deinit();

    var cit = mod.clocks.iterator();
    while (cit.next()) |entry| {
        const c = entry.value_ptr.*;
        out.print("clock {s}", .{c.name}) catch return 3;
        if (c.period) |p| out.print(" period {d}", .{p}) catch return 3;
        if (c.master) |m| out.print(" master {s} /{d}", .{ m, c.divide_by }) catch return 3;
        out.print("\n", .{}) catch return 3;
    }
    for (warnings.items) |w| out.print("warning line {d}: {s}\n", .{ w.line, w.text }) catch return 3;
    for (mod.warnings) |w| out.print("warning: {s}\n", .{w.text}) catch return 3;
    return 0;
}
