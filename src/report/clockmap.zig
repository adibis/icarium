// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const clock = @import("../clock.zig");
const common = @import("common.zig");
const crossing = @import("../crossing.zig");
const ir = @import("../ir.zig");
const rule = @import("../rule.zig");
const sdc = @import("../sdc.zig");
const sync = @import("../sync.zig");

pub const schema_version = "1.0";

// Native clock-map.json: clocks, groups, false paths, per-flop
// domains, typed ports, and structural crossings each tagged
// with its recognized synchronizer and touching findings. Map
// facts reuse rule-pack predicates, so maps cannot drift from
// what lint accepts.
pub fn writeClockMap(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    asg: *const clock.trace.Assignment,
    report: *const crossing.enumerate.Report,
    table: *sync.table.Table,
    marks: *const sync.attrs.Marks,
    findings: []const rule.finding.Finding,
    version: []const u8,
) error{ OutOfMemory, WriteFailed }!void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tmp = arena.allocator();
    const idx = try common.Index.build(tmp, mod);

    var root = std.json.ObjectMap.empty;
    try root.put(tmp, "schema_version", .{ .string = schema_version });
    var gen = std.json.ObjectMap.empty;
    try gen.put(tmp, "name", .{ .string = "icarium" });
    try gen.put(tmp, "version", .{ .string = version });
    try root.put(tmp, "generator", .{ .object = gen });
    var design = std.json.ObjectMap.empty;
    try design.put(tmp, "top", .{ .string = mod.name });
    try design.put(tmp, "frontend", .{ .string = "yosys" });
    try root.put(tmp, "design", .{ .object = design });
    try root.put(tmp, "clocks", try clocksValue(tmp, model, false));
    try root.put(tmp, "generated_clocks", try clocksValue(tmp, model, true));
    try root.put(tmp, "clock_groups", try groupsValue(tmp, model));
    try root.put(tmp, "false_path_pairs", try falsePathsValue(tmp, model));
    try root.put(tmp, "flop_domains", try flopDomainsValue(tmp, mod, asg));
    try root.put(tmp, "port_domains", try portDomainsValue(tmp, mod, model));
    try root.put(tmp, "crossings", try crossingsValue(tmp, mod, &idx, report, table, marks, findings));

    const doc: std.json.Value = .{ .object = root };
    std.json.Stringify.value(doc, .{ .whitespace = .indent_2 }, writer) catch return error.WriteFailed;
    writer.writeByte('\n') catch return error.WriteFailed;
}

// Plain and generated clocks split on master: generated
// entries carry the divide/multiply derivation with them.
fn clocksValue(tmp: std.mem.Allocator, model: *const sdc.model.Model, generated: bool) error{OutOfMemory}!std.json.Value {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    var it = model.clocks.iterator();
    while (it.next()) |e| {
        if ((e.value_ptr.master != null) != generated) continue;
        try names.append(tmp, e.key_ptr.*);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var out = std.json.Array.init(tmp);
    for (names.items) |n| {
        const c = model.clocks.get(n).?;
        var o = std.json.ObjectMap.empty;
        try o.put(tmp, "name", .{ .string = c.name });
        if (c.period) |p| {
            try o.put(tmp, "period", .{ .float = p });
        } else {
            try o.put(tmp, "period", .null);
        }
        try o.put(tmp, "source", .{ .string = "create_clock" });
        if (generated) {
            try o.put(tmp, "master", .{ .string = c.master.? });
            try o.put(tmp, "divide_by", .{ .integer = c.divide_by });
            try o.put(tmp, "multiply_by", .{ .integer = c.multiply_by });
        }
        try o.put(tmp, "ports", try clockPorts(tmp, model, n));
        try out.append(.{ .object = o });
    }
    return .{ .array = out };
}

// Clock roots invert to ports: create_clock names the roots,
// the map reads them back per clock, sorted for stability.
fn clockPorts(tmp: std.mem.Allocator, model: *const sdc.model.Model, want: []const u8) error{OutOfMemory}!std.json.Value {
    var ports = std.ArrayListUnmanaged([]const u8).empty;
    var it = model.clock_roots.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.value_ptr.*, want)) try ports.append(tmp, e.key_ptr.*);
    }
    std.mem.sort([]const u8, ports.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var out = std.json.Array.init(tmp);
    for (ports.items) |p| try out.append(.{ .string = p });
    return .{ .array = out };
}

// One entry per set_clock_groups command: the model stores
// each -group list separately, linked by set id, and the map
// rejoins consecutive same-set lists into members.
fn groupsValue(tmp: std.mem.Allocator, model: *const sdc.model.Model) error{OutOfMemory}!std.json.Value {
    var out = std.json.Array.init(tmp);
    var i: usize = 0;
    while (i < model.groups.len) {
        var j = i + 1;
        while (j < model.groups.len and model.groups[j].set == model.groups[i].set) j += 1;
        const kind: []const u8 = switch (model.groups[i].kind) {
            .async => "asynchronous",
            .logically_exclusive => "logically_exclusive",
            .physically_exclusive => "physically_exclusive",
        };
        var members = std.json.Array.init(tmp);
        for (model.groups[i..j]) |g| {
            var one = std.json.Array.init(tmp);
            for (g.members) |c| try one.append(.{ .string = c });
            try members.append(.{ .array = one });
        }
        var o = std.json.ObjectMap.empty;
        try o.put(tmp, "kind", .{ .string = kind });
        try o.put(tmp, "members", .{ .array = members });
        try out.append(.{ .object = o });
        i = j;
    }
    return .{ .array = out };
}

fn falsePathsValue(tmp: std.mem.Allocator, model: *const sdc.model.Model) error{OutOfMemory}!std.json.Value {
    var out = std.json.Array.init(tmp);
    for (model.false_paths) |fp| {
        var o = std.json.ObjectMap.empty;
        try o.put(tmp, "from", try strArray(tmp, fp.from));
        try o.put(tmp, "to", try strArray(tmp, fp.to));
        try o.put(tmp, "through", try strArray(tmp, fp.through));
        try out.append(.{ .object = o });
    }
    return .{ .array = out };
}

fn strArray(tmp: std.mem.Allocator, items: [][]const u8) error{OutOfMemory}!std.json.Value {
    var out = std.json.Array.init(tmp);
    for (items) |s| try out.append(.{ .string = s });
    return .{ .array = out };
}

fn flopDomainsValue(
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    asg: *const clock.trace.Assignment,
) error{OutOfMemory}!std.json.Value {
    const order = try tmp.dupe(clock.trace.FlopDomain, asg.flops);
    std.mem.sort(clock.trace.FlopDomain, order, mod, struct {
        fn less(m: *const ir.types.Module, a: clock.trace.FlopDomain, b: clock.trace.FlopDomain) bool {
            return std.mem.order(u8, m.cells[a.cell].name, m.cells[b.cell].name) == .lt;
        }
    }.less);
    var out = std.json.Array.init(tmp);
    for (order) |f| {
        const c = mod.cells[f.cell];
        var o = std.json.ObjectMap.empty;
        try o.put(tmp, "cell", .{ .string = c.name });
        try o.put(tmp, "instance", .{ .string = try common.joinPath(tmp, c.instance_path) });
        try o.put(tmp, "clock", .{ .string = f.domain.name });
        if (c.src) |s| {
            if (common.fileLoc(s)) |l| {
                try o.put(tmp, "location", try common.locValue(tmp, l));
            } else {
                try o.put(tmp, "location", .null);
            }
        } else {
            try o.put(tmp, "location", .null);
        }
        try out.append(.{ .object = o });
    }
    return .{ .array = out };
}

// Typed ports only: untyped ports are CDC-011's subject, and
// the map records assignments, not gaps.
fn portDomainsValue(
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
) error{OutOfMemory}!std.json.Value {
    const order = try tmp.dupe(ir.types.ModulePort, mod.ports);
    std.mem.sort(ir.types.ModulePort, order, {}, struct {
        fn less(_: void, a: ir.types.ModulePort, b: ir.types.ModulePort) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    var out = std.json.Array.init(tmp);
    for (order) |p| {
        const clk = sdc.model.portClock(model, p.name) orelse continue;
        var o = std.json.ObjectMap.empty;
        try o.put(tmp, "port", .{ .string = p.name });
        try o.put(tmp, "clock", .{ .string = clk });
        try o.put(tmp, "kind", .{ .string = if (p.direction == .input) "input" else "output" });
        try out.append(.{ .object = o });
    }
    return .{ .array = out };
}

fn crossingsValue(
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    idx: *const common.Index,
    report: *const crossing.enumerate.Report,
    table: *sync.table.Table,
    marks: *const sync.attrs.Marks,
    findings: []const rule.finding.Finding,
) error{OutOfMemory}!std.json.Value {
    var out = std.json.Array.init(tmp);
    for (report.crossings) |x| {
        var o = std.json.ObjectMap.empty;
        try o.put(tmp, "id", .{ .string = x.id });
        try o.put(tmp, "kind", .{ .string = @tagName(x.kind) });
        try o.put(tmp, "src", try endValue(tmp, mod, idx, x.src));
        try o.put(tmp, "dst", try endValue(tmp, mod, idx, x.dst));
        try o.put(tmp, "src_clock", .{ .string = x.src_clk });
        try o.put(tmp, "dst_clock", .{ .string = x.dst_clk });
        try o.put(tmp, "async_per_sdc", .{ .bool = x.async_per_sdc });
        try o.put(tmp, "width", .{ .integer = @as(i64, @intCast(@max(x.lanes.len, 1))) });
        try o.put(tmp, "hops", .{ .integer = @as(i64, @intCast(x.hops.len)) });
        const scheme = try synchronizer(mod, table, marks, x);
        if (scheme) |s| {
            try o.put(tmp, "synchronizer", .{ .string = s });
        } else {
            try o.put(tmp, "synchronizer", .null);
        }
        try o.put(tmp, "findings", try touchingFindings(tmp, mod, x, findings));
        try out.append(.{ .object = o });
    }
    return .{ .array = out };
}

// Endpoints stay joinable, not verbose: cell records live in
// flop_domains, so crossings carry names plus instances.
fn endValue(
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    idx: *const common.Index,
    e: crossing.enumerate.Endpoint,
) error{OutOfMemory}!std.json.Value {
    const name: []const u8 = if (e.cell) |c| mod.cells[c].name else e.port;
    const r = try common.resolve(tmp, mod, idx, name);
    const kind: []const u8 = switch (r.kind) {
        .cell => "cell",
        .port => "port",
        .other => "other",
    };
    var o = std.json.ObjectMap.empty;
    try o.put(tmp, "name", .{ .string = name });
    try o.put(tmp, "kind", .{ .string = kind });
    try o.put(tmp, "instance", .{ .string = r.instance });
    return .{ .object = o };
}

// The scheme the rule pack would accept here: a 2FF chain or
// sync mark first, then handshake, then a static source. Pulse
// and gray shapes stay null until their recognizers are shared;
// a bare crossing reports no scheme rather than a wrong one.
fn synchronizer(
    mod: *const ir.types.Module,
    table: *sync.table.Table,
    marks: *const sync.attrs.Marks,
    x: crossing.enumerate.Crossing,
) error{OutOfMemory}!?[]const u8 {
    switch (x.kind) {
        .clock_sink, .clock_control => return null,
        else => {},
    }
    const dc = x.dst.cell orelse return null;
    const dt = mod.cells[dc].type;
    if (!clock.cells.isSequential(dt) or clock.cells.isLatch(dt)) return null;
    const dst_name = mod.cells[dc].name;
    if (marks.hasSync(dst_name)) return "2ff";
    const depth = try table.chainDepth(mod, dc, x.dst_clk);
    if (depth.depth >= 2) return "2ff";
    if (marks.hasHandshake(dst_name)) return "handshake";
    if (x.src.cell) |sc| {
        if (marks.hasStatic(mod.cells[sc].name)) return "static";
    }
    return null;
}

// Findings touching a crossing are those naming its receiver:
// grouped rules report no crossing id, so the dst cell is the
// join key, and multi-source receivers share their findings.
fn touchingFindings(
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    x: crossing.enumerate.Crossing,
    findings: []const rule.finding.Finding,
) error{OutOfMemory}!std.json.Value {
    const dc = x.dst.cell orelse return .{ .array = std.json.Array.init(tmp) };
    const want = mod.cells[dc].name;
    var seen = std.StringHashMapUnmanaged(void).empty;
    var ids = std.ArrayListUnmanaged([]const u8).empty;
    for (findings) |f| {
        if (f.waiver != null) continue;
        if (!std.mem.eql(u8, f.dst, want)) continue;
        if (seen.contains(f.rule)) continue;
        try seen.put(tmp, f.rule, {});
        try ids.append(tmp, f.rule);
    }
    std.mem.sort([]const u8, ids.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var out = std.json.Array.init(tmp);
    for (ids.items) |id| try out.append(.{ .string = id });
    return .{ .array = out };
}
