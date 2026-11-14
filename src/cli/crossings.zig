// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const crossing = @import("../crossing.zig");
const ir = @import("../ir.zig");
const sdc = @import("../sdc.zig");
const toon = @import("../report.zig").toon;

pub fn run(init: std.process.Init, out: anytype, err: anytype, argv: []const []const u8) u8 {
    var json_path: ?[]const u8 = null;
    var sdc_path: ?[]const u8 = null;
    var top: ?[]const u8 = null;
    var format: []const u8 = "text";
    var stream = false;
    var stream_chunk: usize = 256;
    var pair_budget: usize = 2000000;
    var progress = false;
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
        } else if (std.mem.eql(u8, a, "--format") and i + 1 < argv.len) {
            format = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--stream")) {
            stream = true;
        } else if (std.mem.eql(u8, a, "--progress")) {
            progress = true;
        } else if (std.mem.eql(u8, a, "--pair-budget") and i + 1 < argv.len) {
            pair_budget = std.fmt.parseInt(usize, argv[i + 1], 10) catch {
                err.print("crossings: bad --pair-budget: {s}\n", .{argv[i + 1]}) catch {};
                return 2;
            };
            if (pair_budget == 0) {
                err.writeAll("crossings: --pair-budget must be >= 1\n") catch {};
                return 2;
            }
            i += 1;
        } else if (std.mem.eql(u8, a, "--stream-chunk") and i + 1 < argv.len) {
            stream_chunk = std.fmt.parseInt(usize, argv[i + 1], 10) catch {
                err.print("crossings: bad --stream-chunk: {s}\n", .{argv[i + 1]}) catch {};
                return 2;
            };
            if (stream_chunk == 0) {
                err.writeAll("crossings: --stream-chunk must be >= 1\n") catch {};
                return 2;
            }
            i += 1;
        } else {
            err.print("crossings: bad argument: {s}\n", .{a}) catch {};
            return 2;
        }
    }
    const path = json_path orelse {
        err.writeAll("crossings: missing --yosys-json FILE\n") catch {};
        return 2;
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1 << 30)) catch {
        err.print("crossings: cannot read {s}\n", .{path}) catch {};
        return 3;
    };
    defer init.gpa.free(bytes);

    var mod = ir.load.loadFromSlice(init.gpa, bytes, top) catch |e| {
        err.print("crossings: ingestion failed: {t}\n", .{e}) catch {};
        return 3;
    };
    defer mod.deinit();

    const scratch = init.arena.allocator();
    var warnings: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    var sdc_mod: sdc.model.Model = undefined;
    if (sdc_path) |sp| {
        const sdc_bytes = std.Io.Dir.cwd().readFileAlloc(init.io, sp, init.gpa, .limited(1 << 26)) catch {
            err.print("crossings: cannot read {s}\n", .{sp}) catch {};
            return 3;
        };
        defer init.gpa.free(sdc_bytes);
        sdc_mod = sdc.model.fromSlice(init.gpa, scratch, sdc_bytes, &warnings) catch return 3;
    } else {
        sdc_mod = sdc.model.build(init.gpa, &[_]sdc.commands.Parsed{}) catch return 3;
    }
    defer sdc_mod.deinit();

    const toon_out = if (std.mem.eql(u8, format, "text"))
        false
    else if (std.mem.eql(u8, format, "toon"))
        true
    else {
        err.print("crossings: bad --format: {s}\n", .{format}) catch {};
        return 2;
    };

    var clock_asg = clock.trace.assign(init.gpa, &mod, &sdc_mod, &warnings) catch return 3;
    defer clock_asg.deinit();
    for (warnings.items) |w| w.print(sdc_path, err);
    if (stream) {
        var counts = CountState{ .alloc = scratch, .progress = progress };
        crossing.enumerate.streamBatches(init.gpa, &mod, &clock_asg, &sdc_mod, stream_chunk, pair_budget, &counts, CountState.onBatch) catch return 3;
        counts.print(out) catch return 3;
        return 0;
    }
    var report = crossing.enumerate.enumerate(init.gpa, &mod, &clock_asg, &sdc_mod) catch return 3;
    defer report.deinit();

    if (toon_out) {
        toon.writeCrossingsToon(scratch, out, &mod, &report) catch return 3;
        return 0;
    }
    for (report.crossings) |x| {
        const src = crossing.enumerate.renderEndpoint(scratch, &mod, x.src.cell, x.src.port, x.src.bit) catch return 3;
        defer scratch.free(src);
        const dst = crossing.enumerate.renderEndpoint(scratch, &mod, x.dst.cell, x.dst.port, x.dst.bit) catch return 3;
        defer scratch.free(dst);
        out.print("crossing {s} {t} {s} {s} {s} {s} async {}\n", .{
            x.id, x.kind, src, dst, x.src_clk, x.dst_clk, x.async_per_sdc,
        }) catch return 3;
        for (x.lanes) |l| out.print("lane {s} {d} {d}\n", .{ x.id, l.src_lane, l.dst_lane }) catch return 3;
        for (x.hops) |h| out.print("hop {s} {s}\n", .{ x.id, mod.cells[h].name }) catch return 3;
    }
    return 0;
}

// Streamed census: per-kind counts plus the async split, for
// designs whose pair list no report can hold. Kinds print
// sorted so reruns diff cleanly.
const CountState = struct {
    alloc: std.mem.Allocator,
    kinds: std.StringHashMapUnmanaged(usize) = .empty,
    total: usize = 0,
    async_true: usize = 0,
    chunks: usize = 0,
    progress: bool = false,

    fn onBatch(st: *CountState, batch: crossing.enumerate.Batch) error{OutOfMemory}!void {
        for (batch.crossings) |x| {
            st.total += 1;
            if (x.async_per_sdc) st.async_true += 1;
            const slot = try st.kinds.getOrPut(st.alloc, @tagName(x.kind));
            slot.value_ptr.* = (if (slot.found_existing) slot.value_ptr.* else 0) + 1;
        }
        st.chunks += 1;
        if (st.progress) std.debug.print("stream: chunk {d} pairs {d} crossings {d} total {d}\n", .{ st.chunks, batch.pairs, batch.crossings.len, st.total });
    }

    fn print(st: *CountState, out: anytype) !void {
        var names = std.ArrayListUnmanaged([]const u8).empty;
        var it = st.kinds.iterator();
        while (it.next()) |e| try names.append(st.alloc, e.key_ptr.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        try out.print("crossings total {d} async {d}\n", .{ st.total, st.async_true });
        for (names.items) |k| try out.print("crossings {s} {d}\n", .{ k, st.kinds.get(k).? });
    }
};
