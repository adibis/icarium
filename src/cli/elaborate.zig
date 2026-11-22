// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Runs Yosys so `check` can take RTL directly. The recipe matches
// scripts/elaborate.sh: near-RTL structure only, no opt or techmap,
// so flops and muxes stay visible to the rules.
pub const Frontend = enum { stock, slang };

pub const Options = struct {
    top: ?[]const u8 = null,
    frontend: Frontend = .stock,
    includes: []const []const u8 = &.{},
    defines: []const []const u8 = &.{},
    files: []const []const u8,
};

// Yosys splits its script on whitespace and `;`. read_verilog strips
// quotes from file names but not from -I or -D values, and read_slang
// strips them from nothing. An argument Yosys would misread is refused
// here rather than elaborated wrongly.
pub const Bad = struct { what: []const u8, arg: []const u8 };

pub fn validate(o: Options) ?Bad {
    const quoted = o.frontend == .stock;
    for (o.files) |f| if (!safe(f, quoted)) return .{ .what = "source file", .arg = f };
    for (o.includes) |d| if (!safe(d, false)) return .{ .what = "include directory", .arg = d };
    for (o.defines) |d| if (!safe(d, false)) return .{ .what = "define", .arg = d };
    if (o.top) |t| if (!safe(t, false)) return .{ .what = "top", .arg = t };
    return null;
}

fn safe(s: []const u8, quoted: bool) bool {
    if (s.len == 0) return false;
    for (s) |ch| switch (ch) {
        '"', ';', '#' => return false,
        ' ' => if (!quoted) return false,
        else => if (ch < 0x20 or ch == 0x7f) return false,
    };
    return true;
}

// The Yosys script for a validated Options. JSON goes to stdout.
pub fn script(alloc: std.mem.Allocator, o: Options) error{OutOfMemory}![]u8 {
    var s = std.ArrayListUnmanaged(u8).empty;
    errdefer s.deinit(alloc);
    try s.appendSlice(alloc, switch (o.frontend) {
        .stock => "read_verilog -sv",
        .slang => "read_slang",
    });
    for (o.includes) |d| try s.print(alloc, " -I {s}", .{d});
    for (o.defines) |d| try s.print(alloc, " -D {s}", .{d});
    if (o.frontend == .slang) if (o.top) |t| try s.print(alloc, " --top {s}", .{t});
    for (o.files) |f| switch (o.frontend) {
        .stock => try s.print(alloc, " \"{s}\"", .{f}),
        .slang => try s.print(alloc, " {s}", .{f}),
    };
    if (o.top) |t|
        try s.print(alloc, "; hierarchy -check -top {s}", .{t})
    else
        try s.appendSlice(alloc, "; hierarchy -check -auto-top");
    try s.appendSlice(alloc, "; proc; flatten; write_json");
    return s.toOwnedSlice(alloc);
}

pub const Error = error{ NoYosys, NoSlang, Failed, OutOfMemory };

// Elaborates and returns the netlist JSON. Yosys runs quiet, so its
// stderr carries only warnings and errors, and is passed through for
// the user to read.
pub fn run(alloc: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, err: anytype, o: Options) Error![]u8 {
    const yosys = env.get("YOSYS") orelse "yosys";
    const plugin = if (o.frontend == .slang) try slangFlag(alloc, io, yosys) else false;
    const sc = try script(alloc, o);
    defer alloc.free(sc);

    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, yosys);
    if (plugin) try argv.appendSlice(alloc, &.{ "-m", "slang" });
    try argv.appendSlice(alloc, &.{ "-q", "-p", sc });

    const r = std.process.run(alloc, io, .{ .argv = argv.items }) catch |e| return switch (e) {
        error.FileNotFound => error.NoYosys,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
    defer alloc.free(r.stderr);
    err.writeAll(r.stderr) catch {};
    if (!r.term.success()) {
        alloc.free(r.stdout);
        return error.Failed;
    }
    return r.stdout;
}

// read_slang is built into some Yosys distributions and a plugin in
// others. Returns whether `-m slang` is needed.
fn slangFlag(alloc: std.mem.Allocator, io: std.Io, yosys: []const u8) Error!bool {
    if (try hasSlang(alloc, io, &.{ yosys, "-p", "help read_slang" })) return false;
    if (try hasSlang(alloc, io, &.{ yosys, "-m", "slang", "-p", "help read_slang" })) return true;
    return error.NoSlang;
}

// `help` exits 0 for a command that does not exist, so look for the
// command's own usage line instead.
fn hasSlang(alloc: std.mem.Allocator, io: std.Io, argv: []const []const u8) Error!bool {
    const r = std.process.run(alloc, io, .{ .argv = argv }) catch |e| return switch (e) {
        error.FileNotFound => error.NoYosys,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
    defer alloc.free(r.stdout);
    alloc.free(r.stderr);
    return r.term.success() and std.mem.indexOf(u8, r.stdout, "read_slang [") != null;
}
