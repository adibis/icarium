const std = @import("std");
const args = @import("cli/args.zig");
const check = @import("cli/check.zig");
const clocks = @import("cli/clocks.zig");
const crossings = @import("cli/crossings.zig");
const domains = @import("cli/domains.zig");
const resets = @import("cli/resets.zig");
const rules = @import("cli/rules.zig");
const stats = @import("cli/stats.zig");

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
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    while (it.next()) |a| try argv.append(init.arena.allocator(), a);
    if (argv.items.len < 2) {
        try usage(&stderr.interface);
        return 2;
    }

    const cmd = args.parse(argv.items[1]) orelse {
        try stderr.interface.print("unknown command: {s}\n\n", .{argv.items[1]});
        try usage(&stderr.interface);
        return 2;
    };
    switch (cmd) {
        .help => {
            try usage(&stdout.interface);
            return 0;
        },
        .version => {
            try stdout.interface.print("icarium {s}\n", .{version});
            return 0;
        },
        .stats => return stats.run(init, &stdout.interface, &stderr.interface, argv.items[2..]),
        .clocks => return clocks.run(init, &stdout.interface, &stderr.interface, argv.items[2..]),
        .domains => return domains.run(init, &stdout.interface, &stderr.interface, argv.items[2..]),
        .resets => return resets.run(init, &stdout.interface, &stderr.interface, argv.items[2..]),
        .crossings => return crossings.run(init, &stdout.interface, &stderr.interface, argv.items[2..]),
        .check => return check.run(init, &stdout.interface, &stderr.interface, argv.items[2..]),
        .rules => return rules.run(init, &stdout.interface, &stderr.interface, argv.items[2..]),
    }
}

fn usage(w: anytype) !void {
    try w.writeAll(
        \\icarium: open-source structural CDC/RDC checker
        \\
        \\usage: icarium <command>
        \\
        \\  help              show this text
        \\  version           show version
        \\  stats             summarize a Yosys JSON netlist
        \\      --yosys-json FILE   input from scripts/elaborate.sh
        \\      --top TOP           top module (default: single module)
        \\  clocks            show clocks parsed from an SDC file
        \\      --sdc FILE          constraints file
        \\  domains           show clock domain per sequential cell
        \\      --yosys-json FILE   input from scripts/elaborate.sh
        \\      --top TOP           top module (default: single module)
        \\      --sdc FILE          constraints file (optional)
        \\  resets            show reset source per sequential cell
        \\      --yosys-json FILE   input from scripts/elaborate.sh
        \\      --top TOP           top module (default: single module)
        \\      --sdc FILE          constraints file (optional)
        \\  crossings         enumerate structural crossings
        \\      --yosys-json FILE   input from scripts/elaborate.sh
        \\      --top TOP           top module (default: single module)
        \\      --sdc FILE          constraints file (optional)
        \\  check             run CDC/RDC rules over a netlist
        \\      --yosys-json FILE   input from scripts/elaborate.sh
        \\      --top TOP           top module (default: single module)
        \\      --sdc FILE          constraints file (optional)
        \\      --only IDS          comma-separated rule allowlist
        \\      --skip IDS          comma-separated rule blocklist
        \\      --format FMT        text (default), ids, or json
        \\      --minify            minified json (with --format json)
        \\      --sync-depth N      required chain depth (default 2)
        \\      --cdc-010-no-heuristic  disable library pin-name guessing
        \\      --cdc-018-depth-threshold N  cascade warn depth (default 4)
        \\      --sync-primitive NAME   site CDC macro (repeatable)
        \\  rules             list rules (--list) or show docs (--doc)
        \\
    );
}
