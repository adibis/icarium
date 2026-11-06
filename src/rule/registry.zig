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
const cdc015 = @import("cdc015.zig");
const cdc016 = @import("cdc016.zig");
const cdc017 = @import("cdc017.zig");
const cdc018 = @import("cdc018.zig");
const cdc019 = @import("cdc019.zig");
const cdc020 = @import("cdc020.zig");
const cdc021 = @import("cdc021.zig");
const cdc022 = @import("cdc022.zig");
const cdc023 = @import("cdc023.zig");
const cdc024 = @import("cdc024.zig");
const cdc025 = @import("cdc025.zig");
const cdc026 = @import("cdc026.zig");
const rdc001 = @import("rdc001.zig");
const rdc002 = @import("rdc002.zig");
const rdc003 = @import("rdc003.zig");
const rdc004 = @import("rdc004.zig");
const rdc005 = @import("rdc005.zig");
const rdc006 = @import("rdc006.zig");
const rdc007 = @import("rdc007.zig");
const rdc008 = @import("rdc008.zig");
const rdc009 = @import("rdc009.zig");
const rdc010 = @import("rdc010.zig");
const rdc011 = @import("rdc011.zig");
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

// Streaming disposition: xing rules ride the per-crossing
// loop, batch rules see one chunk, once rules see the whole
// design a single time, accum rules fold chunks into state.
pub const Scope = enum { xing, batch, once, accum };

pub const Pass = enum { all, batch, once, finish };

const scopes = std.StaticStringMap(Scope).initComptime(.{
    .{ "CDC-001", .xing },  .{ "CDC-002", .xing },
    .{ "CDC-003", .xing },  .{ "CDC-004", .xing },
    .{ "CDC-005", .batch }, .{ "CDC-006", .once },
    .{ "CDC-008", .once },  .{ "CDC-009", .xing },
    .{ "CDC-010", .once },  .{ "CDC-011", .batch },
    .{ "CDC-012", .batch }, .{ "CDC-013", .xing },
    .{ "CDC-014", .xing },  .{ "CDC-015", .batch },
    .{ "CDC-016", .batch }, .{ "CDC-017", .once },
    .{ "CDC-018", .batch }, .{ "CDC-019", .accum },
    .{ "CDC-020", .batch }, .{ "CDC-021", .once },
    .{ "CDC-022", .once },  .{ "CDC-023", .once },
    .{ "CDC-024", .batch }, .{ "CDC-025", .accum },
    .{ "CDC-026", .accum }, .{ "RDC-001", .once },
    .{ "RDC-002", .once },  .{ "RDC-003", .once },
    .{ "RDC-004", .once },  .{ "RDC-005", .once },
    .{ "RDC-006", .once },  .{ "RDC-007", .once },
    .{ "RDC-008", .once },  .{ "RDC-009", .once },
    .{ "RDC-010", .once },  .{ "RDC-011", .once },
});

fn scopeOf(id: []const u8) Scope {
    return scopes.get(id) orelse unreachable;
}

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
    cdc015.rule,
    cdc016.rule,
    cdc017.rule,
    cdc018.rule,
    cdc019.rule,
    cdc020.rule,
    cdc021.rule,
    cdc022.rule,
    cdc023.rule,
    cdc024.rule,
    cdc025.rule,
    cdc026.rule,
    rdc001.rule,
    rdc002.rule,
    rdc003.rule,
    rdc004.rule,
    rdc005.rule,
    rdc006.rule,
    rdc007.rule,
    rdc008.rule,
    rdc009.rule,
    rdc010.rule,
    rdc011.rule,
};

fn knownAttr(name: []const u8) bool {
    for ([_]struct { m: *const std.StaticStringMap(void), ci: bool }{
        .{ .m = &sync.attrs.sync_names, .ci = true },
        .{ .m = &sync.attrs.static_names, .ci = false },
        .{ .m = &sync.attrs.handshake_names, .ci = false },
        .{ .m = &sync.attrs.gray_names, .ci = false },
        .{ .m = &sync.attrs.glitchless_names, .ci = false },
        .{ .m = &sync.attrs.reset_sync_names, .ci = false },
        .{ .m = &sync.attrs.reset_polarity_names, .ci = false },
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
    // Twenty rules times map lookups outgrows the default
    // budget; the loop is finite, so raise the ceiling.
    @setEvalBranchQuota(10000);
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
        // Scope must match the hook shape, or streaming would
        // feed a rule crossings it never asked to see per chunk.
        switch (scopeOf(r.id)) {
            .xing => if (r.check == null) @compileError("xing rule needs check"),
            .batch, .once, .accum => if (r.check_all == null) @compileError("whole rule needs check_all"),
        }
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

// One run owns the finding list and the waiver-identity
// set across passes, so streamed batches dedupe globally.
pub const Run = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayListUnmanaged(finding.Finding) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    acc019: cdc019.Accum = .{},
    acc025: cdc025.Accum = .{},
    acc026: cdc026.Accum = .{},

    pub fn init(alloc: std.mem.Allocator) Run {
        return .{ .alloc = alloc };
    }

    pub fn deinit(r: *Run) void {
        var it = r.seen.iterator();
        while (it.next()) |e| r.alloc.free(e.key_ptr.*);
        r.seen.deinit(r.alloc);
    }

    fn accumulateOne(r: *Run, id: []const u8, ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!void {
        if (std.mem.eql(u8, id, "CDC-019")) return cdc019.accumulate(&r.acc019, ctx, x);
        if (std.mem.eql(u8, id, "CDC-025")) return cdc025.accumulate(&r.acc025, ctx, x);
        if (std.mem.eql(u8, id, "CDC-026")) return cdc026.accumulate(&r.acc026, ctx, x);
        unreachable;
    }

    fn finishOne(r: *Run, id: []const u8, ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
        if (std.mem.eql(u8, id, "CDC-019")) return cdc019.finish(&r.acc019, ctx);
        if (std.mem.eql(u8, id, "CDC-025")) return cdc025.finish(&r.acc025, ctx);
        if (std.mem.eql(u8, id, "CDC-026")) return cdc026.finish(&r.acc026, ctx);
        unreachable;
    }

    pub fn runPass(
        r: *Run,
        ctx: *context.Context,
        only: ?[]const []const u8,
        skip: ?[]const []const u8,
        pass: Pass,
    ) error{OutOfMemory}!void {
        for (rules) |rl| {
            if (!enabled(rl.id, only, skip)) continue;
            const scope = scopeOf(rl.id);
            if (!inPass(scope, pass)) continue;
            if (scope == .accum and pass != .all) {
                switch (pass) {
                    .batch => for (ctx.crossings) |x| try r.accumulateOne(rl.id, ctx, x),
                    .finish => for (try r.finishOne(rl.id, ctx)) |f| {
                        if (try fresh(r.alloc, &r.seen, f)) try r.out.append(r.alloc, f);
                    },
                    .all, .once => unreachable,
                }
                continue;
            }
            if (rl.check_all) |whole| {
                for (try whole(ctx)) |f| {
                    if (try fresh(r.alloc, &r.seen, f)) try r.out.append(r.alloc, f);
                }
            } else if (rl.check) |one| {
                for (ctx.crossings) |x| {
                    // Unknown pairs belong to CDC-025's per-endpoint
                    // ledger, never to per-pair structure rules: a sync
                    // violation on an unclocked endpoint is noise with
                    // a confident tone. Matches knownPair in enumerate.
                    if (unknownSide(x)) continue;
                    if (try one(ctx, x)) |got| {
                        var f = got;
                        if (f.driver == null) f.driver = try srcName(ctx, x);
                        if (try fresh(r.alloc, &r.seen, f)) try r.out.append(r.alloc, f);
                    }
                }
            }
        }
    }
};

// Batch runs what chunks can answer; once and finish run
// after the last chunk. All covers the legacy whole-report run.
fn inPass(scope: Scope, pass: Pass) bool {
    return switch (pass) {
        .all => true,
        .batch => scope == .xing or scope == .batch or scope == .accum,
        .once => scope == .once,
        .finish => scope == .accum,
    };
}

// Rules outer, crossings inner: registry order is fixed and
// crossings arrive sorted, so reruns order identically.
// Cost: O(rules × crossings); per-crossing work is each rule's own.
pub fn runChecks(
    alloc: std.mem.Allocator,
    ctx: *context.Context,
    only: ?[]const []const u8,
    skip: ?[]const []const u8,
) error{OutOfMemory}![]finding.Finding {
    var run = Run.init(alloc);
    defer run.deinit();
    try run.runPass(ctx, only, skip, .all);
    return run.out.toOwnedSlice(alloc);
}

// Findings deduplicate on their waiver identity: per-crossing rules
// restate the same fact for every lane, and reporters print each row.
fn fresh(alloc: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), f: finding.Finding) error{OutOfMemory}!bool {
    const key = try std.fmt.allocPrint(alloc, "{s}\x00{s}\x00{s}\x00{s}", .{ f.rule, f.dst, f.driver orelse "", f.message });
    const slot = try seen.getOrPut(alloc, key);
    if (slot.found_existing) {
        alloc.free(key);
        return false;
    }
    slot.key_ptr.* = key;
    return true;
}

// Either end unclocked: untyped port sources ride a port: clock
// or the untyped kind, cells ride unknown. A port: DESTINATION
// is clocked-but-undeclared (CDC-021's shape), never unknown.
// Mirrors knownPair; CDC-025 owns the pairs skipped here.
pub fn unknownSide(x: crossing.enumerate.Crossing) bool {
    if (x.kind == .port_flop_untyped) return true;
    if (std.mem.startsWith(u8, x.src_clk, "port:")) return true;
    return std.mem.eql(u8, x.src_clk, "unknown") or std.mem.eql(u8, x.dst_clk, "unknown");
}

// The crossing's own source endpoint: single-crossing rules
// inherit their driver, and only override when they know better.
// Port names copy out: batch crossings die with their chunk,
// while findings outlive the run.
fn srcName(ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}![]const u8 {
    if (x.src.cell) |sc| return ctx.mod.cells[sc].name;
    return try ctx.alloc.dupe(u8, x.src.port);
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
