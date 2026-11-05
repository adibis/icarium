const std = @import("std");
const clock = @import("../clock.zig");
const crossing = @import("../crossing.zig");
const ir = @import("../ir.zig");
const clockmap = @import("../report.zig").clockmap;
const findings_json = @import("../report.zig").findings;
const report_text = @import("../report.zig").text;
const resetmap = @import("../report.zig").resetmap;
const sarif = @import("../report.zig").sarif;
const suppress = @import("../suppress.zig");
const tool_version = @import("../version.zig").version;
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
    var domain_map_path: ?[]const u8 = null;
    var reset_map_path: ?[]const u8 = null;
    var baseline_path: ?[]const u8 = null;
    var waivers_path: ?[]const u8 = null;
    var strict_waivers = false;
    var no_findings = false;
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
        } else if (std.mem.eql(u8, a, "--emit-domain-map") and i + 1 < argv.len) {
            domain_map_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--emit-reset-domain-map") and i + 1 < argv.len) {
            reset_map_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--waivers") and i + 1 < argv.len) {
            waivers_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--baseline") and i + 1 < argv.len) {
            baseline_path = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--strict-waivers")) {
            strict_waivers = true;
        } else if (std.mem.eql(u8, a, "--no-findings")) {
            no_findings = true;
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
    const fmt: enum { text, ids, json, sarif } = if (std.mem.eql(u8, format, "text"))
        .text
    else if (std.mem.eql(u8, format, "ids"))
        .ids
    else if (std.mem.eql(u8, format, "json"))
        .json
    else if (std.mem.eql(u8, format, "sarif"))
        .sarif
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
    var findings: []rule.finding.Finding = if (no_findings)
        &.{}
    else
        rule.registry.runChecks(scratch, &ctx, only_arg, skip_arg) catch return 3;

    var unmatched: []const []const u8 = &.{};
    var wbytes: []u8 = &.{};
    defer if (wbytes.len > 0) init.gpa.free(wbytes);
    var waived: ?suppress.waivers.Loaded = null;
    defer if (waived) |*l| l.deinit();
    if (waivers_path) |wp| {
        if (no_findings) {
            err.writeAll("check: --waivers ignored with --no-findings\n") catch {};
        } else {
            wbytes = std.Io.Dir.cwd().readFileAlloc(init.io, wp, init.gpa, .limited(1 << 26)) catch {
                err.print("check: cannot read {s}\n", .{wp}) catch {};
                return 3;
            };
            waived = suppress.waivers.load(init.gpa, wbytes) catch {
                err.print("check: bad waivers file {s}\n", .{wp}) catch {};
                return 2;
            };
            const applied = suppress.waivers.apply(scratch, &mod, findings, &waived.?, suppress.waivers.today(init.io), wp) catch return 3;
            for (findings, 0..) |*f, fi| f.waiver = applied.hits[fi];
            unmatched = applied.unmatched;
            for (applied.expired) |id| err.print("check: waiver {s} expired: not applied\n", .{id}) catch {};
            for (unmatched) |id| err.print("check: waiver {s} matched no finding\n", .{id}) catch {};
        }
    } else if (strict_waivers) {
        err.writeAll("check: --strict-waivers without --waivers has no waivers to check\n") catch {};
    }
    if (!no_findings and findings.len > 0) {
        const paths = suppress.pragmas.pragmaFiles(scratch, &mod, findings) catch return 3;
        if (paths.len > 0) {
            const scanned = suppress.pragmas.scanFiles(scratch, init.io, init.gpa, paths) catch return 3;
            for (scanned.missing) |p| err.print("check: cannot read pragma source {s}: pragmas there ignored\n", .{p}) catch {};
            for (scanned.unknown_rules) |u| err.print("check: {s}:{d}: unknown rule {s} in pragma: ignored\n", .{ u.origin, u.line, u.rule }) catch {};
            suppress.pragmas.apply(scratch, &mod, findings, &scanned) catch return 3;
        }
    }
    var carried: u32 = 0;
    var bbytes: []u8 = &.{};
    defer if (bbytes.len > 0) init.gpa.free(bbytes);
    var base: ?suppress.baseline.Baseline = null;
    defer if (base) |*b| b.deinit();
    if (baseline_path) |bp| {
        if (no_findings) {
            err.writeAll("check: --baseline ignored with --no-findings\n") catch {};
        } else {
            bbytes = std.Io.Dir.cwd().readFileAlloc(init.io, bp, init.gpa, .limited(1 << 26)) catch {
                err.print("check: cannot read {s}\n", .{bp}) catch {};
                return 3;
            };
            base = suppress.baseline.load(init.gpa, bbytes) catch {
                err.print("check: bad baseline file {s}\n", .{bp}) catch {};
                return 2;
            };
            const kept = suppress.baseline.partition(scratch, findings, &base.?) catch return 3;
            carried = @intCast(findings.len - kept);
            findings = findings[0..kept];
            if (carried > 0) err.print("check: carried over {d} finding(s) from baseline\n", .{carried}) catch {};
        }
    }

    if (domain_map_path) |mp| {
        var aw = std.Io.Writer.Allocating.init(scratch);
        clockmap.writeClockMap(scratch, &aw.writer, &mod, &sdc_mod, &clock_asg, &report, &table, &marks, findings, tool_version) catch return 3;
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = mp, .data = aw.written() }) catch {
            err.print("check: cannot write {s}\n", .{mp}) catch {};
            return 3;
        };
    }
    if (reset_map_path) |mp| {
        var aw = std.Io.Writer.Allocating.init(scratch);
        resetmap.writeResetMap(scratch, &aw.writer, &mod, &reset_view, &reset_syncs, &table, &marks, tool_version) catch return 3;
        std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = mp, .data = aw.written() }) catch {
            err.print("check: cannot write {s}\n", .{mp}) catch {};
            return 3;
        };
    }
    if (no_findings) {
        if (domain_map_path == null and reset_map_path == null) err.writeAll("check: --no-findings without a map flag produces no output\n") catch {};
        return 0;
    }

    switch (fmt) {
        .json => findings_json.writeJsonOptions(scratch, out, &mod, findings, unmatched, carried, .{ .minify = minify }) catch return 3,
        .text => report_text.writeText(scratch, out, &mod, findings, carried) catch return 3,
        .sarif => sarif.writeSarif(scratch, out, &mod, findings, tool_version) catch return 3,
        .ids => for (findings) |f| {
            rule.finding.renderId(out, f) catch return 3;
        },
    }
    var failed = false;
    for (findings) |f| {
        if (f.severity == .err and f.waiver == null) failed = true;
    }
    if (strict_waivers and unmatched.len > 0) failed = true;
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
