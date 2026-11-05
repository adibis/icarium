const std = @import("std");
const ir = @import("../ir.zig");

pub fn run(init: std.process.Init, out: anytype, err: anytype, argv: []const []const u8) u8 {
    var json_path: ?[]const u8 = null;
    var top: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--yosys-json") and i + 1 < argv.len) {
            json_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--top") and i + 1 < argv.len) {
            top = argv[i + 1];
            i += 1;
        } else {
            err.print("stats: bad argument: {s}\n", .{a}) catch {};
            return 2;
        }
    }
    const path = json_path orelse {
        err.writeAll("stats: missing --yosys-json FILE\n") catch {};
        return 2;
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1 << 30)) catch {
        err.print("stats: cannot read {s}\n", .{path}) catch {};
        return 3;
    };
    defer init.gpa.free(bytes);

    var mod = ir.load.loadFromSlice(init.gpa, bytes, top) catch |e| {
        err.print("stats: ingestion failed: {t}\n", .{e}) catch {};
        return 3;
    };
    defer mod.deinit();

    const scratch = init.arena.allocator();
    const sum = ir.stats.summarize(scratch, &mod) catch return 3;
    const hist = ir.stats.histogram(scratch, &mod) catch return 3;
    out.print("module: {s}\ncells: {d}\nunique bits: {d}\ncells with src: {d}\n", .{
        mod.name, sum.cells, sum.unique_bits, sum.with_src,
    }) catch return 3;
    for (hist) |h| out.print("  {s}: {d}\n", .{ h.name, h.count }) catch return 3;
    return 0;
}
