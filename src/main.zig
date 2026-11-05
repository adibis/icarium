const std = @import("std");

const version = "0.1.0-dev";

pub fn main(init: std.process.Init) !u8 {
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    defer stdout.interface.flush() catch {};
    var err_buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &err_buf);
    defer stderr.interface.flush() catch {};

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.skip();
    const cmd = it.next() orelse {
        try usage(&stderr.interface);
        return 2;
    };
    if (isHelp(cmd)) {
        try usage(&stdout.interface);
        return 0;
    }
    if (isVersion(cmd)) {
        try stdout.interface.print("icarium {s}\n", .{version});
        return 0;
    }
    try stderr.interface.print("unknown command: {s}\n\n", .{cmd});
    try usage(&stderr.interface);
    return 2;
}

fn isHelp(s: []const u8) bool {
    return std.mem.eql(u8, s, "help") or std.mem.eql(u8, s, "--help") or std.mem.eql(u8, s, "-h");
}

fn isVersion(s: []const u8) bool {
    return std.mem.eql(u8, s, "version") or std.mem.eql(u8, s, "--version") or std.mem.eql(u8, s, "-V");
}

fn usage(w: anytype) !void {
    try w.writeAll(
        \\icarium: open-source structural CDC/RDC checker
        \\
        \\usage: icarium <command>
        \\
        \\  help              show this text
        \\  version           show version
        \\
    );
}
