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
    const idx = try common.Index.build(tmp, mod);

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
        if (try bucketed(tmp, mod, &idx, slice)) {
            try writeBuckets(tmp, writer, mod, &idx, slice);
        } else {
            for (slice) |f| try writeItem(tmp, writer, mod, &idx, f, "  ");
        }
        i = j;
    }
    if (carried_over > 0) {
        const noun: []const u8 = if (carried_over == 1) "finding" else "findings";
        writer.print("carried over from baseline: {d} {s}\n", .{ carried_over, noun }) catch return error.WriteFailed;
    }
}

// Buckets earn headers only when a rule spans instances;
// single-bucket groups read flat.
fn bucketed(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    idx: *const common.Index,
    slice: []const rule.finding.Finding,
) error{OutOfMemory}!bool {
    var first: ?[]const u8 = null;
    for (slice) |f| {
        const r = try common.resolve(alloc, mod, idx, f.dst);
        if (first == null) {
            first = r.instance;
        } else if (!std.mem.eql(u8, first.?, r.instance)) {
            return true;
        }
    }
    return false;
}

fn writeBuckets(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    idx: *const common.Index,
    slice: []const rule.finding.Finding,
) error{ OutOfMemory, WriteFailed }!void {
    var seen = std.StringHashMapUnmanaged(void).empty;
    for (slice) |f| {
        const r = try common.resolve(alloc, mod, idx, f.dst);
        if (seen.contains(r.instance)) continue;
        try seen.put(alloc, r.instance, {});
        if (r.instance.len == 0) {
            writer.writeAll("  [top]\n") catch return error.WriteFailed;
        } else {
            writer.print("  {s}\n", .{r.instance}) catch return error.WriteFailed;
        }
        for (slice) |g| {
            const gr = try common.resolve(alloc, mod, idx, g.dst);
            if (!std.mem.eql(u8, gr.instance, r.instance)) continue;
            try writeItem(alloc, writer, mod, idx, g, "    ");
        }
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
    writer.writeAll(f.dst) catch return error.WriteFailed;
    if (dst.src) |s| writer.print(" @ {s}", .{s}) catch return error.WriteFailed;
    if (f.driver) |d| {
        const drv = try common.resolve(alloc, mod, idx, d);
        writer.print(" <- {s}", .{d}) catch return error.WriteFailed;
        if (drv.src) |s| writer.print(" @ {s}", .{s}) catch return error.WriteFailed;
    }
    writer.print(": {s}", .{f.message}) catch return error.WriteFailed;
    if (f.waiver) |w| {
        writer.print(" [waived {s}: {s}", .{ w.id, w.reason }) catch return error.WriteFailed;
        if (w.location) |l| writer.print(" @ {s}", .{l}) catch return error.WriteFailed;
        writer.writeByte(']') catch return error.WriteFailed;
    }
    writer.writeByte('\n') catch return error.WriteFailed;
}
