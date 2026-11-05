const std = @import("std");
const clock = @import("../clock.zig");
const crossing = @import("../crossing.zig");
const ir = @import("../ir.zig");
const findings_json = @import("../report.zig").findings;
const report_text = @import("../report.zig").text;
const reset = @import("../reset.zig");
const rule = @import("../rule.zig");
const sdc = @import("../sdc.zig");
const sync = @import("../sync.zig");

pub fn run(init: std.process.Init, out: anytype, err: anytype, argv: []const []const u8) u8 {
    var json_path: ?[]const u8 = null;
    var sdc_path: ?[]const u8 = null;
    var top: ?[]const u8 = null;
    var only_s: ?[]const u8 = null;
    var skip_s: ?[]const u8 = null;
    var format: []const u8 = "text";
    var minify = false;
    var sync_depth: u32 = 2;
    var depth_threshold: u32 = 4;
    var heuristic = true;
    var prims = std.ArrayListUnmanaged([]const u8).empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--yosys-json") and i + 1 < argv.len) {
            json_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--sdc") and i + 1 < argv.len) {
            sdc_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--top") and i + 1 < argv.len) {
            top = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--only") and i + 1 < argv.len) {
            only_s = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--skip") and i + 1 < argv.len) {
            skip_s = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--format") and i + 1 < argv.len) {
            format = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--cdc-010-no-heuristic")) {
            heuristic = false;
        } else if (std.mem.eql(u8, a, "--minify")) {
            minify = true;
        } else if (std.mem.eql(u8, a, "--sync-depth") and i + 1 < argv.len) {
            sync_depth = std.fmt.parseInt(u32, argv[i + 1], 10) catch {
                err.print("check: bad --sync-depth: {s}\n", .{argv[i + 1]}) catch {};
                return 2;
            };
            i += 1;
        } else if (std.mem.eql(u8, a, "--sync-primitive") and i + 1 < argv.len) {
            prims.append(init.arena.allocator(), argv[i + 1]) catch return 3;
            i += 1;
        } else if (std.mem.eql(u8, a, "--cdc-018-depth-threshold") and i + 1 < argv.len) {
            depth_threshold = std.fmt.parseInt(u32, argv[i + 1], 10) catch {
                err.print("check: bad --cdc-018-depth-threshold: {s}\n", .{argv[i + 1]}) catch {};
                return 2;
            };
            if (depth_threshold < 2) {
                err.writeAll("check: --cdc-018-depth-threshold must be >= 2\n") catch {};
                return 2;
            }
            i += 1;
        } else {
            err.print("check: bad argument: {s}\n", .{a}) catch {};
            return 2;
        }
    }
    const path = json_path orelse {
        err.writeAll("check: missing --yosys-json FILE\n") catch {};
        return 2;
    };
    const fmt: enum { text, ids, json } = if (std.mem.eql(u8, format, "text"))
        .text
    else if (std.mem.eql(u8, format, "ids"))
        .ids
    else if (std.mem.eql(u8, format, "json"))
        .json
    else {
        err.print("check: bad --format: {s}\n", .{format}) catch {};
        return 2;
    };

    const scratch = init.arena.allocator();
    const only = splitIds(scratch, only_s) catch return 3;
    const skip = splitIds(scratch, skip_s) catch return 3;
    for (only) |id| {
        if (rule.registry.find(id) == null) {
            err.print("check: unknown rule: {s}\n", .{id}) catch {};
            return 2;
        }
    }
    for (skip) |id| {
        if (rule.registry.find(id) == null) {
            err.print("check: unknown rule: {s}\n", .{id}) catch {};
            return 2;
        }
    }

    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1 << 30)) catch {
        err.print("check: cannot read {s}\n", .{path}) catch {};
        return 3;
    };
    defer init.gpa.free(bytes);

    var mod = ir.load.loadFromSlice(init.gpa, bytes, top) catch |e| {
        err.print("check: ingestion failed: {t}\n", .{e}) catch {};
        return 3;
    };
    defer mod.deinit();

    var warnings: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    var sdc_mod: sdc.model.Model = undefined;
    if (sdc_path) |sp| {
        const sdc_bytes = std.Io.Dir.cwd().readFileAlloc(init.io, sp, init.gpa, .limited(1 << 26)) catch {
            err.print("check: cannot read {s}\n", .{sp}) catch {};
            return 3;
        };
        defer init.gpa.free(sdc_bytes);
        sdc_mod = sdc.model.fromSlice(init.gpa, scratch, sdc_bytes, &warnings) catch return 3;
    } else {
        sdc_mod = sdc.model.build(init.gpa, &[_]sdc.commands.Parsed{}) catch return 3;
    }
    defer sdc_mod.deinit();

    var clock_asg = clock.trace.assign(init.gpa, &mod, &sdc_mod) catch return 3;
    defer clock_asg.deinit();
    var report = crossing.enumerate.enumerate(init.gpa, &mod, &clock_asg, &sdc_mod) catch return 3;
    defer report.deinit();
    var table = sync.table.build(init.gpa, &mod, &clock_asg) catch return 3;
    defer table.deinit();
    var marks = sync.attrs.collect(init.gpa, &mod) catch return 3;
    defer marks.deinit();
    var reset_view = reset.trace.assign(init.gpa, &mod, &clock_asg) catch return 3;
    defer reset_view.deinit();
    var reset_syncs = reset.chains.find(init.gpa, &mod, &reset_view, &table.domains, &marks.reset_syncs) catch return 3;
    defer reset_syncs.deinit();
    const buses = rule.context.collectBuses(scratch, &report) catch return 3;
    var ctx = rule.context.Context{
        .mod = &mod,
        .model = &sdc_mod,
        .report = &report,
        .table = &table,
        .marks = &marks,
        .reset_view = &reset_view,
        .reset_syncs = &reset_syncs,
        .buses = buses,
        .cfg = .{ .sync_depth = sync_depth, .cdc010_heuristic = heuristic, .cdc018_threshold = depth_threshold, .sync_primitives = prims.items },
        .alloc = scratch,
    };
    const only_arg: ?[]const []const u8 = if (only_s == null) null else only;
    const skip_arg: ?[]const []const u8 = if (skip_s == null) null else skip;
    const findings = rule.registry.runChecks(scratch, &ctx, only_arg, skip_arg) catch return 3;

    switch (fmt) {
        .json => findings_json.writeJsonOptions(scratch, out, &mod, findings, .{ .minify = minify }) catch return 3,
        .text => report_text.writeText(scratch, out, &mod, findings) catch return 3,
        .ids => for (findings) |f| {
            rule.finding.renderId(out, f) catch return 3;
        },
    }
    var failed = false;
    for (findings) |f| {
        if (f.severity == .err) failed = true;
    }
    return if (failed) 1 else 0;
}

fn splitIds(alloc: std.mem.Allocator, s: ?[]const u8) error{OutOfMemory}![][]const u8 {
    const text = s orelse return &.{};
    var out = std.ArrayListUnmanaged([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |id| {
        if (id.len == 0) continue;
        try out.append(alloc, id);
    }
    return out.toOwnedSlice(alloc);
}
