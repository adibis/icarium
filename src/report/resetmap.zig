const std = @import("std");
const common = @import("common.zig");
const ir = @import("../ir.zig");
const reset = @import("../reset.zig");
const rule = @import("../rule.zig");
const sync = @import("../sync.zig");

pub const schema_version = "1.0";

// Native reset-map.json: reset sources, recognized synchronizer
// chains, per-flop reset assignments, and structural reset
// crossings in the async-deassert / polarity-mismatch /
// sync-crossing / comb-driven vocabulary. Crossings are
// structural facts from the reset view, independent of which
// RDC rules fire, so map-only runs stay meaningful.
pub fn writeResetMap(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    mod: *const ir.types.Module,
    view: *const reset.trace.View,
    syncs: *const reset.chains.Syncs,
    table: *sync.table.Table,
    marks: *const sync.attrs.Marks,
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
    try root.put(tmp, "reset_sources", try sourcesValue(tmp, mod, &idx, view, syncs, table, marks));
    try root.put(tmp, "reset_synchronizers", try synchronizersValue(tmp, mod, syncs, table));
    try root.put(tmp, "flop_resets", try flopResetsValue(tmp, mod, view));
    try root.put(tmp, "reset_crossings", try crossingsValue(tmp, mod, &idx, view, syncs, table, marks));

    const doc: std.json.Value = .{ .object = root };
    std.json.Stringify.value(doc, .{ .whitespace = .indent_2 }, writer) catch return error.WriteFailed;
    writer.writeByte('\n') catch return error.WriteFailed;
}

fn originWord(o: reset.trace.Origin) []const u8 {
    return switch (o) {
        .port => "port",
        .flop => "flop",
        .constant => "constant",
        .mux => "mux",
        .comb => "comb",
        .unknown => "unknown",
    };
}

fn polarityWord(p: reset.trace.Polarity) []const u8 {
    return switch (p) {
        .high => "high",
        .low => "low",
        .unknown => "unknown",
    };
}

const SourceKey = struct { ref: []const u8, kind: u8 };
const SourceCtx = struct {
    pub fn hash(_: SourceCtx, k: SourceKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.ref);
        h.update(&[_]u8{k.kind});
        return h.final();
    }
    pub fn eql(_: SourceCtx, a: SourceKey, b: SourceKey) bool {
        return a.kind == b.kind and std.mem.eql(u8, a.ref, b.ref);
    }
};

const Source = struct {
    origin: reset.trace.Origin,
    is_sync: bool,
    polarity: reset.trace.Polarity,
};

// Distinct reset roots over async and sync entries: async and
// sync uses of one root stay separate rows, since deassertion
// hazards differ by pin type.
fn sourcesValue(
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    idx: *const common.Index,
    view: *const reset.trace.View,
    syncs: *const reset.chains.Syncs,
    table: *sync.table.Table,
    marks: *const sync.attrs.Marks,
) error{OutOfMemory}!std.json.Value {
    var seen = std.HashMapUnmanaged(SourceKey, Source, SourceCtx, std.hash_map.default_max_load_percentage).empty;
    for (view.flops) |fr| {
        for (fr.async) |ar| {
            const key = SourceKey{ .ref = ar.ref, .kind = 0 };
            const slot = try seen.getOrPut(tmp, key);
            if (!slot.found_existing) slot.value_ptr.* = .{ .origin = ar.origin, .is_sync = false, .polarity = ar.polarity };
        }
        if (fr.sync.kind != .none) {
            const key = SourceKey{ .ref = syncRef(fr.sync), .kind = 1 };
            const slot = try seen.getOrPut(tmp, key);
            if (!slot.found_existing) slot.value_ptr.* = .{ .origin = syncOrigin(fr.sync), .is_sync = true, .polarity = .unknown };
        }
    }
    var keys = std.ArrayListUnmanaged(SourceKey).empty;
    var sit = seen.iterator();
    while (sit.next()) |e| try keys.append(tmp, e.key_ptr.*);
    std.mem.sort(SourceKey, keys.items, {}, struct {
        fn less(_: void, a: SourceKey, b: SourceKey) bool {
            if (a.kind != b.kind) return a.kind < b.kind;
            return std.mem.order(u8, a.ref, b.ref) == .lt;
        }
    }.less);
    var tails = std.StringHashMapUnmanaged(void).empty;
    for (syncs.chains) |ch| try tails.put(tmp, mod.cells[ch.flops[0]].name, {});
    var out = std.json.Array.init(tmp);
    for (keys.items) |k| {
        const s = seen.get(k).?;
        var o = std.json.ObjectMap.empty;
        try o.put(tmp, "name", .{ .string = k.ref });
        try o.put(tmp, "source", .{ .string = originWord(s.origin) });
        if (s.origin == .port) {
            const declared = marks.resetPolarity(k.ref);
            if (declared) |d| {
                try o.put(tmp, "polarity", .{ .string = polarityWord(d) });
                try o.put(tmp, "declared_polarity", .{ .string = polarityWord(d) });
            } else {
                try o.put(tmp, "polarity", .{ .string = polarityWord(s.polarity) });
                try o.put(tmp, "declared_polarity", .null);
            }
        } else {
            try o.put(tmp, "polarity", .{ .string = polarityWord(s.polarity) });
            try o.put(tmp, "declared_polarity", .null);
        }
        try o.put(tmp, "type", .{ .string = if (s.is_sync) "sync" else "async" });
        if (s.origin == .flop) {
            if (idx.by_cell.get(k.ref)) |ci| {
                if (table.domainOf(ci)) |d| {
                    try o.put(tmp, "clock", .{ .string = d.name });
                } else {
                    try o.put(tmp, "clock", .null);
                }
                try o.put(tmp, "location", try cellLoc(tmp, mod.cells[ci]));
            } else {
                try o.put(tmp, "clock", .null);
                try o.put(tmp, "location", .null);
            }
        } else {
            try o.put(tmp, "clock", .null);
            try o.put(tmp, "location", .null);
        }
        try o.put(tmp, "via_synchronizer", .{ .bool = tails.contains(k.ref) });
        try out.append(.{ .object = o });
    }
    return .{ .array = out };
}

// A sync entry names its stimulus by origin where resolved;
// an unresolved mux falls back to the mux cell itself.
fn syncRef(s: reset.trace.SyncReset) []const u8 {
    if (s.origin != .unknown) return s.origin_ref;
    if (s.kind == .mux) return s.ref;
    return "";
}

fn syncOrigin(s: reset.trace.SyncReset) reset.trace.Origin {
    if (s.origin != .unknown) return s.origin;
    if (s.kind == .mux) return .mux;
    return .unknown;
}

fn synchronizersValue(
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    syncs: *const reset.chains.Syncs,
    table: *sync.table.Table,
) error{OutOfMemory}!std.json.Value {
    var out = std.json.Array.init(tmp);
    for (syncs.chains) |ch| {
        const tail = ch.flops[0];
        var stages = std.json.Array.init(tmp);
        for (ch.flops) |f| try stages.append(.{ .string = mod.cells[f].name });
        var o = std.json.ObjectMap.empty;
        try o.put(tmp, "tail", .{ .string = mod.cells[tail].name });
        try o.put(tmp, "stages", .{ .array = stages });
        if (table.domainOf(tail)) |d| {
            try o.put(tmp, "clock", .{ .string = d.name });
        } else {
            try o.put(tmp, "clock", .null);
        }
        try o.put(tmp, "polarity", .{ .string = polarityWord(ch.polarity) });
        switch (ch.head_d) {
            .zero => try o.put(tmp, "head_d", .{ .string = "0" }),
            .one => try o.put(tmp, "head_d", .{ .string = "1" }),
            else => try o.put(tmp, "head_d", .null),
        }
        try out.append(.{ .object = o });
    }
    return .{ .array = out };
}

// One row per reset pin: async entries first, then the sync
// entry where the flop has one. Pin order is module order,
// already stable across runs.
fn flopResetsValue(
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    view: *const reset.trace.View,
) error{OutOfMemory}!std.json.Value {
    var out = std.json.Array.init(tmp);
    for (view.flops) |fr| {
        const c = mod.cells[fr.cell];
        const inst = try common.joinPath(tmp, c.instance_path);
        for (fr.async) |ar| {
            var o = std.json.ObjectMap.empty;
            try o.put(tmp, "cell", .{ .string = c.name });
            try o.put(tmp, "instance", .{ .string = inst });
            try o.put(tmp, "clock", .{ .string = fr.clock.name });
            try o.put(tmp, "reset", .{ .string = ar.ref });
            try o.put(tmp, "reset_kind", .{ .string = originWord(ar.origin) });
            try o.put(tmp, "polarity", .{ .string = polarityWord(ar.polarity) });
            try o.put(tmp, "type", .{ .string = "async" });
            try o.put(tmp, "location", try cellLoc(tmp, c));
            try out.append(.{ .object = o });
        }
        if (fr.sync.kind != .none) {
            var o = std.json.ObjectMap.empty;
            try o.put(tmp, "cell", .{ .string = c.name });
            try o.put(tmp, "instance", .{ .string = inst });
            try o.put(tmp, "clock", .{ .string = fr.clock.name });
            try o.put(tmp, "reset", .{ .string = syncRef(fr.sync) });
            try o.put(tmp, "reset_kind", .{ .string = originWord(syncOrigin(fr.sync)) });
            try o.put(tmp, "polarity", .{ .string = "unknown" });
            try o.put(tmp, "type", .{ .string = "sync" });
            try o.put(tmp, "location", try cellLoc(tmp, c));
            try out.append(.{ .object = o });
        }
    }
    return .{ .array = out };
}

fn cellLoc(tmp: std.mem.Allocator, c: ir.types.Cell) error{OutOfMemory}!std.json.Value {
    if (c.src) |s| {
        if (common.fileLoc(s)) |l| return common.locValue(tmp, l);
    }
    return .null;
}

// Structural reset arrivals worth flagging: foreign-domain
// async and sync sources, declared-vs-param polarity splits,
// and flopped comb drivers. Chain members bridge safely, so
// they never appear; unknowns stay silent rather than guess.
fn crossingsValue(
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    idx: *const common.Index,
    view: *const reset.trace.View,
    syncs: *const reset.chains.Syncs,
    table: *sync.table.Table,
    marks: *const sync.attrs.Marks,
) error{OutOfMemory}!std.json.Value {
    var out = std.json.Array.init(tmp);
    for (view.flops) |fr| {
        const c = mod.cells[fr.cell];
        if (syncs.isMember(c.name)) continue;
        if (std.mem.eql(u8, fr.clock.name, "unknown")) continue;
        const inst = try common.joinPath(tmp, c.instance_path);
        for (fr.async) |ar| {
            if (ar.origin == .flop and foreignFlop(table, idx, ar.ref, fr.clock.name)) {
                try out.append(try crossingRow(tmp, c, inst, fr.clock.name, ar, "async-deassert", "async"));
            }
            if (ar.origin == .port) {
                if (marks.resetPolarity(ar.ref)) |declared| {
                    const param = reset.chains.paramPolarity(c, ar.pin);
                    if (param != declared) {
                        try out.append(try crossingRow(tmp, c, inst, fr.clock.name, ar, "polarity-mismatch", "async"));
                    }
                }
            }
            if (ar.origin == .comb and try floppedDriver(tmp, mod, c, ar.pin)) {
                try out.append(try crossingRow(tmp, c, inst, fr.clock.name, ar, "comb-driven", "async"));
            }
        }
        if (fr.sync.kind != .none and fr.sync.origin == .flop and
            foreignFlop(table, idx, fr.sync.origin_ref, fr.clock.name))
        {
            var row = std.json.ObjectMap.empty;
            try row.put(tmp, "cell", .{ .string = c.name });
            try row.put(tmp, "instance", .{ .string = inst });
            try row.put(tmp, "kind", .{ .string = "sync-crossing" });
            try row.put(tmp, "flop_clock", .{ .string = fr.clock.name });
            try row.put(tmp, "reset", .{ .string = fr.sync.origin_ref });
            try row.put(tmp, "reset_kind", .{ .string = "flop" });
            try row.put(tmp, "polarity", .{ .string = "unknown" });
            try row.put(tmp, "type", .{ .string = "sync" });
            try row.put(tmp, "location", try cellLoc(tmp, c));
            try out.append(.{ .object = row });
        }
    }
    return .{ .array = out };
}

fn crossingRow(
    tmp: std.mem.Allocator,
    c: ir.types.Cell,
    inst: []const u8,
    flop_clock: []const u8,
    ar: reset.trace.AsyncReset,
    kind: []const u8,
    rtype: []const u8,
) error{OutOfMemory}!std.json.Value {
    var row = std.json.ObjectMap.empty;
    try row.put(tmp, "cell", .{ .string = c.name });
    try row.put(tmp, "instance", .{ .string = inst });
    try row.put(tmp, "kind", .{ .string = kind });
    try row.put(tmp, "flop_clock", .{ .string = flop_clock });
    try row.put(tmp, "reset", .{ .string = ar.ref });
    try row.put(tmp, "reset_kind", .{ .string = originWord(ar.origin) });
    try row.put(tmp, "polarity", .{ .string = polarityWord(ar.polarity) });
    try row.put(tmp, "type", .{ .string = rtype });
    try row.put(tmp, "location", try cellLoc(tmp, c));
    return .{ .object = row };
}

// A flop source in a known, different domain: unknown clocks
// on either side veto the verdict instead of forcing one.
fn foreignFlop(
    table: *sync.table.Table,
    idx: *const common.Index,
    name: []const u8,
    consumer: []const u8,
) bool {
    const ci = idx.by_cell.get(name) orelse return false;
    const dom = table.domainOf(ci) orelse return false;
    if (std.mem.eql(u8, dom.name, "unknown")) return false;
    return !std.mem.eql(u8, dom.name, consumer);
}

// Flop Q behind the pin through combinational logic: the walk
// is the same bounded fanin the rules use, so verdicts agree.
fn floppedDriver(
    tmp: std.mem.Allocator,
    mod: *const ir.types.Module,
    c: ir.types.Cell,
    pin: []const u8,
) error{OutOfMemory}!bool {
    const bits = c.portBits(pin) orelse return false;
    const fanin = try rule.context.backwardFlopFanin(tmp, mod, bits);
    return fanin.items.len > 0;
}
