// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const common = @import("common.zig");
const ir = @import("../ir.zig");
const rule = @import("../rule.zig");

// Grouped human text: one rule header per firing rule, items
// bucketed by destination instance. Buckets collapse when a
// rule's items share one instance; silence stays silent.
pub fn writeText(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    findings: []const rule.finding.Finding,
    carried_over: u32,
) error{ OutOfMemory, WriteFailed }!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tmp = arena.allocator();

    const ordered = try tmp.dupe(rule.finding.Finding, findings);
    std.mem.sort(rule.finding.Finding, ordered, {}, rule.finding.Finding.less);
    const idx = try common.Index.buildFor(tmp, mod, ordered);

    var i: usize = 0;
    while (i < ordered.len) {
        var j = i + 1;
        while (j < ordered.len and std.mem.eql(u8, ordered[j].rule, ordered[i].rule)) j += 1;
        const slice = ordered[i..j];
        const noun: []const u8 = if (slice.len == 1) "finding" else "findings";
        writer.print("{s} [{s}] {s} ({d} {s})\n", .{
            slice[0].rule,
            common.severityWord(slice[0].severity),
            common.ruleTitle(slice[0].rule),
            slice.len,
            noun,
        }) catch return error.WriteFailed;
        try writeGroup(tmp, writer, mod, &idx, slice);
        i = j;
    }
    if (carried_over > 0) {
        const noun: []const u8 = if (carried_over == 1) "finding" else "findings";
        writer.print("carried over from baseline: {d} {s}\n", .{ carried_over, noun }) catch return error.WriteFailed;
    }
}

// Buckets earn headers only when a rule spans instances;
// single-bucket groups read flat.
fn writeGroup(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    idx: *const common.Index,
    slice: []const rule.finding.Finding,
) error{ OutOfMemory, WriteFailed }!void {
    if (slice.len == 0) return;
    // One resolve per item: per-bucket rescans go quadratic.
    const inst = try alloc.alloc([]const u8, slice.len);
    for (slice, 0..) |f, i| inst[i] = (try common.resolve(alloc, mod, idx, f.dst)).instance;
    var multi = false;
    for (inst[1..]) |r| {
        if (!std.mem.eql(u8, r, inst[0])) {
            multi = true;
            break;
        }
    }
    if (!multi) {
        for (slice) |f| try writeItem(alloc, writer, mod, idx, f, "  ");
        return;
    }
    // Buckets print first-seen, members in slice order,
    // matching the rescan's order without revisiting it.
    var order = std.ArrayListUnmanaged([]const u8).empty;
    var members = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)).empty;
    for (inst, 0..) |r, i| {
        const slot = try members.getOrPut(alloc, r);
        if (!slot.found_existing) {
            slot.value_ptr.* = .empty;
            try order.append(alloc, r);
        }
        try slot.value_ptr.append(alloc, i);
    }
    for (order.items) |r| {
        if (r.len == 0) {
            writer.writeAll("  [top]\n") catch return error.WriteFailed;
        } else {
            writer.print("  {s}\n", .{r}) catch return error.WriteFailed;
        }
        for (members.get(r).?.items) |i| try writeItem(alloc, writer, mod, idx, slice[i], "    ");
    }
}

fn writeItem(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    idx: *const common.Index,
    f: rule.finding.Finding,
    indent: []const u8,
) error{ OutOfMemory, WriteFailed }!void {
    const dst = try common.resolve(alloc, mod, idx, f.dst);
    writer.writeAll(indent) catch return error.WriteFailed;
    writer.writeAll(dst.signal) catch return error.WriteFailed;
    if (dst.src) |s| writer.print(" @ {s}", .{s}) catch return error.WriteFailed;
    if (f.driver) |d| {
        const drv = try common.resolve(alloc, mod, idx, d);
        writer.print(" <- {s}", .{drv.signal}) catch return error.WriteFailed;
        if (drv.src) |s| writer.print(" @ {s}", .{s}) catch return error.WriteFailed;
    }
    writer.print(": {s}", .{try common.displayMessage(alloc, idx, f.message)}) catch return error.WriteFailed;
    if (f.waiver) |w| {
        writer.print(" [waived {s}: {s}", .{ w.id, w.reason }) catch return error.WriteFailed;
        if (w.location) |l| writer.print(" @ {s}", .{l}) catch return error.WriteFailed;
        writer.writeByte(']') catch return error.WriteFailed;
    }
    writer.writeByte('\n') catch return error.WriteFailed;
}
