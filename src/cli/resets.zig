// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const ir = @import("../ir.zig");
const reset = @import("../reset.zig");
const sdc = @import("../sdc.zig");

pub fn run(init: std.process.Init, out: anytype, err: anytype, argv: []const []const u8) u8 {
    var json_path: ?[]const u8 = null;
    var sdc_path: ?[]const u8 = null;
    var top: ?[]const u8 = null;
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
        } else {
            err.print("resets: bad argument: {s}\n", .{a}) catch {};
            return 2;
        }
    }
    const path = json_path orelse {
        err.writeAll("resets: missing --yosys-json FILE\n") catch {};
        return 2;
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1 << 30)) catch {
        err.print("resets: cannot read {s}\n", .{path}) catch {};
        return 3;
    };
    defer init.gpa.free(bytes);

    var mod = ir.load.loadFromSlice(init.gpa, bytes, top) catch |e| {
        err.print("resets: ingestion failed: {t}\n", .{e}) catch {};
        return 3;
    };
    defer mod.deinit();

    const scratch = init.arena.allocator();
    var warnings: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    var sdc_mod: sdc.model.Model = undefined;
    if (sdc_path) |sp| {
        const sdc_bytes = std.Io.Dir.cwd().readFileAlloc(init.io, sp, init.gpa, .limited(1 << 26)) catch {
            err.print("resets: cannot read {s}\n", .{sp}) catch {};
            return 3;
        };
        defer init.gpa.free(sdc_bytes);
        sdc_mod = sdc.model.fromSlice(init.gpa, scratch, sdc_bytes, &warnings) catch return 3;
    } else {
        sdc_mod = sdc.model.build(init.gpa, &[_]sdc.commands.Parsed{}) catch return 3;
    }
    defer sdc_mod.deinit();

    var clock_asg = clock.trace.assign(init.gpa, &mod, &sdc_mod, &warnings) catch return 3;
    defer clock_asg.deinit();
    for (warnings.items) |w| w.print(sdc_path, err);
    var view = reset.trace.assign(init.gpa, &mod, &clock_asg, null) catch return 3;
    defer view.deinit();

    // Sorted by cell name so repeated runs diff cleanly.
    const order = scratch.alloc(usize, view.flops.len) catch return 3;
    for (order, 0..) |*o, k| o.* = k;
    const Ctx = struct {
        flops: []reset.trace.FlopReset,
        mod: *const ir.types.Module,
    };
    std.mem.sort(usize, order, Ctx{ .flops = view.flops, .mod = &mod }, struct {
        fn less(ctx: Ctx, a: usize, b: usize) bool {
            const na = ctx.mod.cells[ctx.flops[a].cell].name;
            const nb = ctx.mod.cells[ctx.flops[b].cell].name;
            return std.mem.lessThan(u8, na, nb);
        }
    }.less);
    for (order) |k| {
        const f = view.flops[k];
        const name = mod.cells[f.cell].name;
        out.print("flop {s} clock {s}\n", .{ name, f.clock.name }) catch return 3;
        for (f.async) |a| {
            const ref = if (a.ref.len == 0) "-" else a.ref;
            out.print("async {s} {s} origin {t} ref {s} polarity {t}\n", .{ name, a.pin, a.origin, ref, a.polarity }) catch return 3;
            for (a.notes) |n| out.print("note {s} {s} {s}\n", .{ name, a.pin, n }) catch return 3;
        }
        if (f.sync.kind == .none) {
            out.print("sync {s} none\n", .{name}) catch return 3;
        } else {
            out.print("sync {s} {t} {s}\n", .{ name, f.sync.kind, f.sync.ref }) catch return 3;
        }
        for (f.sync.notes) |n| out.print("note {s} sync {s}\n", .{ name, n }) catch return 3;
    }
    return 0;
}
