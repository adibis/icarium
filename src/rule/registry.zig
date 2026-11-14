// SPDX-License-Identifier: Apache-2.0

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

// One struct per rule: flags, docs, and fixtures generate
// from this list. Chunk-folding rules add one row to accum_mods
// or range_mods below; their dispatch generates from that row,
// so a rule stays one file plus data rows.
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
// design a single time, accum rules fold chunks into state,
// range rules fold one ledger range, then finish and reset.
pub const Scope = enum { xing, batch, once, accum, range };

pub const Pass = enum { all, batch, once, finish };

const scopes = std.StaticStringMap(Scope).initComptime(.{
    .{ "CDC-001", .xing },  .{ "CDC-002", .xing },
    .{ "CDC-003", .xing },  .{ "CDC-004", .xing },
    .{ "CDC-005", .range }, .{ "CDC-006", .once },
    .{ "CDC-008", .once },  .{ "CDC-009", .xing },
    .{ "CDC-010", .once },  .{ "CDC-011", .accum },
    .{ "CDC-012", .batch }, .{ "CDC-013", .xing },
    .{ "CDC-014", .xing },  .{ "CDC-015", .batch },
    .{ "CDC-016", .batch }, .{ "CDC-017", .once },
    .{ "CDC-018", .accum }, .{ "CDC-019", .accum },
    .{ "CDC-020", .range }, .{ "CDC-021", .once },
    .{ "CDC-022", .once },  .{ "CDC-023", .once },
    .{ "CDC-024", .range }, .{ "CDC-025", .accum },
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

// One row per chunk-folding rule: id, Run state field, module.
// accumulateOne/finishOne unroll from accum_mods, the range
// driver from range_mods; the comptime checks below fail the
// build when a row and its scope disagree.
const accum_mods = .{
    .{ .id = "CDC-011", .field = "acc011", .M = cdc011 },
    .{ .id = "CDC-018", .field = "acc018", .M = cdc018 },
    .{ .id = "CDC-019", .field = "acc019", .M = cdc019 },
    .{ .id = "CDC-025", .field = "acc025", .M = cdc025 },
    .{ .id = "CDC-026", .field = "acc026", .M = cdc026 },
};

const range_mods = .{
    .{ .id = "CDC-005", .field = "r005", .M = cdc005 },
    .{ .id = "CDC-020", .field = "r020", .M = cdc020 },
    .{ .id = "CDC-024", .field = "r024", .M = cdc024 },
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
    // Dozens of rules times map lookups outgrows the default
    // budget; the loop is finite, so raise the ceiling.
    @setEvalBranchQuota(100000);
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
            .batch, .once, .accum, .range => if (r.check_all == null) @compileError("whole rule needs check_all"),
        }
        // Folding scopes need their dispatch row, or the rule
        // silently never runs under streaming.
        if (scopeOf(r.id) == .accum and !hasMod(accum_mods, r.id)) @compileError("accum rule missing from accum_mods");
        if (scopeOf(r.id) == .range and !hasMod(range_mods, r.id)) @compileError("range rule missing from range_mods");
    }
    for (accum_mods) |am| {
        if (scopeOf(am.id) != .accum) @compileError("accum_mods row is not an accum rule");
    }
    for (range_mods) |rm| {
        if (scopeOf(rm.id) != .range) @compileError("range_mods row is not a range rule");
    }
}

fn hasMod(comptime mods: anytype, id: []const u8) bool {
    inline for (mods) |m| {
        if (std.mem.eql(u8, id, m.id)) return true;
    }
    return false;
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
// Range ledgers ride their own arena: exact per-source sets
// that finish and free at each range end, never accumulating
// across the run the way whole-design ledgers must.
pub const Run = struct {
    alloc: std.mem.Allocator,
    gpa: std.mem.Allocator,
    out: std.ArrayListUnmanaged(finding.Finding) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    acc011: cdc011.Accum = .{},
    acc018: cdc018.Accum = .{},
    acc019: cdc019.Accum = .{},
    acc025: cdc025.Accum = .{},
    acc026: cdc026.Accum = .{},
    r005: cdc005.Accum = .{},
    r020: cdc020.Accum = .{},
    r024: cdc024.Accum = .{},
    range_arena: std.heap.ArenaAllocator = undefined,

    pub fn init(alloc: std.mem.Allocator, gpa: std.mem.Allocator) Run {
        return .{ .alloc = alloc, .gpa = gpa, .range_arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(r: *Run) void {
        var it = r.seen.iterator();
        while (it.next()) |e| r.alloc.free(e.key_ptr.*);
        r.seen.deinit(r.alloc);
        r.range_arena.deinit();
    }

    fn accumulateOne(r: *Run, id: []const u8, ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}!void {
        inline for (accum_mods) |am| {
            if (std.mem.eql(u8, id, am.id)) return am.M.accumulate(&@field(r, am.field), ctx, x);
        }
        unreachable;
    }

    fn finishOne(r: *Run, id: []const u8, ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
        inline for (accum_mods) |am| {
            if (std.mem.eql(u8, id, am.id)) return am.M.finish(&@field(r, am.field), ctx);
        }
        unreachable;
    }

    // Range rules fold the batch into the range arena, which the
    // driver frees at range end. Groups key on source cells, and
    // ranges never split a cell, so each group lands complete.
    pub fn runRangeBatch(
        r: *Run,
        ctx: *context.Context,
        only: ?[]const []const u8,
        skip: ?[]const []const u8,
    ) error{OutOfMemory}!void {
        for (ctx.crossings) |x| {
            inline for (range_mods) |rm| {
                if (enabled(rm.id, only, skip)) try rm.M.accumulate(&@field(r, rm.field), ctx, x);
            }
        }
    }

    // Range end: finish each rule's groups into findings, then
    // drop the arena. Findings copy out; the ledger does not
    // survive, which is what bounds a million-range run.
    pub fn endRange(
        r: *Run,
        ctx: *context.Context,
        only: ?[]const []const u8,
        skip: ?[]const []const u8,
    ) error{OutOfMemory}!void {
        inline for (range_mods) |rm| {
            if (enabled(rm.id, only, skip)) for (try rm.M.finish(&@field(r, rm.field), ctx)) |f| {
                if (try fresh(ctx.tmp, r.alloc, &r.seen, f)) try r.out.append(r.alloc, try retain(r.alloc, f));
            };
        }
        inline for (range_mods) |rm| {
            @field(r, rm.field) = .{};
        }
        r.range_arena.deinit();
        r.range_arena = std.heap.ArenaAllocator.init(r.gpa);
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
                        if (try fresh(ctx.tmp, r.alloc, &r.seen, f)) try r.out.append(r.alloc, try retain(r.alloc, f));
                    },
                    .all, .once => unreachable,
                }
                continue;
            }
            if (rl.check_all) |whole| {
                for (try whole(ctx)) |f| {
                    if (try fresh(ctx.tmp, r.alloc, &r.seen, f)) try r.out.append(r.alloc, try retain(r.alloc, f));
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
                        if (try fresh(ctx.tmp, r.alloc, &r.seen, f)) try r.out.append(r.alloc, try retain(r.alloc, f));
                    }
                }
            }
        }
    }
};

// Batch runs what chunks can answer; once and finish run
// after the last chunk. All covers the legacy whole-report run,
// where range rules ride their check_all whole-report hook.
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
    var run = Run.init(alloc, alloc);
    defer run.deinit();
    try run.runPass(ctx, only, skip, .all);
    return run.out.toOwnedSlice(alloc);
}

// Dedupe probes ride tmp; only novel keys copy to alloc.
// Arena free is a no-op, so freed probes would still retain.
fn fresh(tmp: std.mem.Allocator, alloc: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), f: finding.Finding) error{OutOfMemory}!bool {
    const key = try std.fmt.allocPrint(tmp, "{s}\x00{s}\x00{s}\x00{s}", .{ f.rule, f.dst, f.driver orelse "", f.message });
    const slot = try seen.getOrPut(alloc, key);
    if (slot.found_existing) return false;
    slot.key_ptr.* = try alloc.dupe(u8, key);
    return true;
}

// Kept findings copy out of tmp, which dies with the batch.
// Uniform copies: immortal names duplicate cheaply too.
fn retain(alloc: std.mem.Allocator, f: finding.Finding) error{OutOfMemory}!finding.Finding {
    var kept = f;
    kept.dst = try alloc.dupe(u8, f.dst);
    if (f.driver) |d| kept.driver = try alloc.dupe(u8, d);
    kept.message = try alloc.dupe(u8, f.message);
    return kept;
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

// The crossing's source endpoint for driverless findings.
// Port names ride tmp; kept findings copy out in retain.
fn srcName(ctx: *context.Context, x: crossing.enumerate.Crossing) error{OutOfMemory}![]const u8 {
    if (x.src.cell) |sc| return ctx.mod.cells[sc].name;
    return try ctx.tmp.dupe(u8, x.src.port);
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
