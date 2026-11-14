// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const ir = @import("../ir.zig");
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
            err.print("domains: bad argument: {s}\n", .{a}) catch {};
            return 2;
        }
    }
    const path = json_path orelse {
        err.writeAll("domains: missing --yosys-json FILE\n") catch {};
        return 2;
    };

    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1 << 30)) catch {
        err.print("domains: cannot read {s}\n", .{path}) catch {};
        return 3;
    };
    defer init.gpa.free(bytes);

    var mod = ir.load.loadFromSlice(init.gpa, bytes, top) catch |e| {
        err.print("domains: ingestion failed: {t}\n", .{e}) catch {};
        return 3;
    };
    defer mod.deinit();

    const scratch = init.arena.allocator();
    var warnings: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    // No SDC means every root is undeclared: still total, every
    // domain synthetic, and CDC-021 will say so rule by rule.
    var sdc_mod: sdc.model.Model = undefined;
    if (sdc_path) |sp| {
        const sdc_bytes = std.Io.Dir.cwd().readFileAlloc(init.io, sp, init.gpa, .limited(1 << 26)) catch {
            err.print("domains: cannot read {s}\n", .{sp}) catch {};
            return 3;
        };
        defer init.gpa.free(sdc_bytes);
        sdc_mod = sdc.model.fromSlice(init.gpa, scratch, sdc_bytes, &warnings) catch return 3;
    } else {
        sdc_mod = sdc.model.build(init.gpa, &[_]sdc.commands.Parsed{}) catch return 3;
    }
    defer sdc_mod.deinit();

    var asg = clock.trace.assign(init.gpa, &mod, &sdc_mod, &warnings) catch return 3;
    defer asg.deinit();
    for (warnings.items) |w| w.print(sdc_path, err);

    // Sorted by cell name so repeated runs diff cleanly.
    const order = scratch.alloc(usize, asg.flops.len) catch return 3;
    for (order, 0..) |*o, k| o.* = k;
    const Ctx = struct {
        flops: []clock.trace.FlopDomain,
        mod: *const ir.types.Module,
    };
    std.mem.sort(usize, order, Ctx{ .flops = asg.flops, .mod = &mod }, struct {
        fn less(ctx: Ctx, a: usize, b: usize) bool {
            const na = ctx.mod.cells[ctx.flops[a].cell].name;
            const nb = ctx.mod.cells[ctx.flops[b].cell].name;
            return std.mem.lessThan(u8, na, nb);
        }
    }.less);
    for (order) |k| {
        const f = asg.flops[k];
        const name = mod.cells[f.cell].name;
        out.print("flop {s} domain {s}\n", .{ name, f.domain.name }) catch return 3;
        for (f.domain.notes) |n| out.print("note {s} {s}\n", .{ name, n }) catch return 3;
    }
    // Controls sorted by cell, then pin, so output diffs cleanly.
    const c_order = scratch.alloc(usize, asg.controls.len) catch return 3;
    for (c_order, 0..) |*o, k| o.* = k;
    const CCtx = struct {
        controls: []clock.trace.ControlPin,
        mod: *const ir.types.Module,
    };
    std.mem.sort(usize, c_order, CCtx{ .controls = asg.controls, .mod = &mod }, struct {
        fn less(ctx: CCtx, a: usize, b: usize) bool {
            const na = ctx.mod.cells[ctx.controls[a].cell].name;
            const nb = ctx.mod.cells[ctx.controls[b].cell].name;
            if (!std.mem.eql(u8, na, nb)) return std.mem.lessThan(u8, na, nb);
            return std.mem.lessThan(u8, ctx.controls[a].pin, ctx.controls[b].pin);
        }
    }.less);
    for (c_order) |k| {
        const cp = asg.controls[k];
        const name = mod.cells[cp.cell].name;
        out.print("control {s} {s} domain {s}\n", .{ name, cp.pin, cp.domain.name }) catch return 3;
        for (cp.domain.notes) |n| out.print("note {s} {s} {s}\n", .{ name, cp.pin, n }) catch return 3;
    }
    return 0;
}
