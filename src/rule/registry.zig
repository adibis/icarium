const std = @import("std");
const cdc001 = @import("cdc001.zig");
const cdc002 = @import("cdc002.zig");
const cdc003 = @import("cdc003.zig");
const cdc004 = @import("cdc004.zig");
const cdc005 = @import("cdc005.zig");
const cdc006 = @import("cdc006.zig");
const cdc008 = @import("cdc008.zig");
const cdc009 = @import("cdc009.zig");
const cdc010 = @import("cdc010.zig");
const cdc011 = @import("cdc011.zig");
const cdc012 = @import("cdc012.zig");
const cdc013 = @import("cdc013.zig");
const cdc014 = @import("cdc014.zig");
const context = @import("context.zig");
const crossing = @import("../crossing.zig");
const finding = @import("finding.zig");
const sync = @import("../sync.zig");

pub const Severity = enum { err, warn, note };

// One struct per rule: dispatch, flags, docs, and fixtures all
// generate from this list, so a rule is one file plus one row.
pub const Rule = struct {
    id: []const u8,
    severity: Severity,
    title: []const u8,
    doc: []const u8,
    honors: []const []const u8,
    check: ?*const fn (*context.Context, crossing.enumerate.Crossing) error{OutOfMemory}!?finding.Finding = null,
    check_all: ?*const fn (*context.Context) error{OutOfMemory}![]finding.Finding = null,
};

pub const rules = [_]Rule{
    cdc001.rule,
    cdc002.rule,
    cdc003.rule,
    cdc004.rule,
    cdc005.rule,
    cdc006.rule,
    cdc008.rule,
    cdc009.rule,
    cdc010.rule,
    cdc011.rule,
    cdc012.rule,
    cdc013.rule,
    cdc014.rule,
};

fn knownAttr(name: []const u8) bool {
    for ([_]struct { m: *const std.StaticStringMap(void), ci: bool }{
        .{ .m = &sync.attrs.sync_names, .ci = true },
        .{ .m = &sync.attrs.static_names, .ci = false },
        .{ .m = &sync.attrs.handshake_names, .ci = false },
        .{ .m = &sync.attrs.gray_names, .ci = false },
        .{ .m = &sync.attrs.glitchless_names, .ci = false },
    }) |t| {
        if (t.ci) {
            for (t.m.keys()) |k| {
                if (std.ascii.eqlIgnoreCase(name, k)) return true;
            }
        } else if (t.m.get(name) != null) {
            return true;
        }
    }
    return false;
}

comptime {
    // Strictly sorted doubles as unique: any duplicate or
    // misordering fails the build at the offending row.
    for (rules[0 .. rules.len - 1], rules[1..]) |a, b| {
        if (!std.mem.lessThan(u8, a.id, b.id)) {
            @compileError("rule IDs must be unique and sorted");
        }
    }
    for (rules) |r| {
        for (r.honors) |h| {
            if (!knownAttr(h)) @compileError("rule honors unknown attribute");
        }
        const hooks: u2 = (if (r.check != null) 1 else 0) + (if (r.check_all != null) 1 else 0);
        if (hooks != 1) @compileError("rule needs exactly one of check/check_all");
    }
}

pub fn find(id: []const u8) ?Rule {
    for (rules) |r| {
        if (std.mem.eql(u8, r.id, id)) return r;
    }
    return null;
}

fn enabled(id: []const u8, only: ?[]const []const u8, skip: ?[]const []const u8) bool {
    if (only) |o| {
        var hit = false;
        for (o) |w| {
            if (std.mem.eql(u8, w, id)) hit = true;
        }
        if (!hit) return false;
    }
    if (skip) |s| {
        for (s) |w| {
            if (std.mem.eql(u8, w, id)) return false;
        }
    }
    return true;
}

// Rules outer, crossings inner: registry order is fixed and
// crossings arrive sorted, so reruns order identically.
pub fn runChecks(
    alloc: std.mem.Allocator,
    ctx: *context.Context,
    only: ?[]const []const u8,
    skip: ?[]const []const u8,
) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    for (rules) |r| {
        if (!enabled(r.id, only, skip)) continue;
        if (r.check_all) |whole| {
            const fs = try whole(ctx);
            try out.appendSlice(alloc, fs);
        } else if (r.check) |one| {
            for (ctx.report.crossings) |x| {
                if (try one(ctx, x)) |f| try out.append(alloc, f);
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn renderList(out: anytype) !void {
    for (rules) |r| try out.print("{s}\n", .{r.id});
}

pub fn renderDoc(out: anytype) !void {
    for (rules) |r| {
        try out.print("{s} [{t}] {s}\n", .{ r.id, r.severity, r.title });
        try out.print("{s}\n", .{r.doc});
        try out.writeAll("honors:");
        for (r.honors) |h| try out.print(" {s}", .{h});
        try out.print("\nfixtures: fixtures/{s}\n\n", .{r.id});
    }
}
