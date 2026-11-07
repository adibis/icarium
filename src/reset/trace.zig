const std = @import("std");
const cells = @import("cells.zig");
const clock = @import("../clock.zig");
const ir = @import("../ir.zig");

pub const Origin = enum { port, flop, constant, mux, comb, unknown };

pub const Polarity = enum { high, low, unknown };

pub const AsyncReset = struct {
    pin: []const u8,
    origin: Origin,
    ref: []const u8,
    // Inversions between source and pin: chain recognition folds
    // them into the shared-reset signature, so opposite-polarity
    // legs never count as one reset.
    flips: u32,
    polarity: Polarity,
    notes: [][]const u8,
};

pub const SyncKind = enum { none, pin, mux };

pub const SyncReset = struct {
    kind: SyncKind,
    ref: []const u8,
    origin: Origin,
    origin_ref: []const u8,
    // The $mux cell for .mux, for rules walking the select bits.
    mux: ?usize = null,
    notes: [][]const u8,
};

pub const FlopReset = struct {
    cell: usize,
    clock: clock.trace.Domain,
    async: []AsyncReset,
    sync: SyncReset,
};

pub const View = struct {
    // Heap-owned, matching Module: copying a live arena orphans
    // later allocations from deinit (see ir/types.zig).
    backing: *std.heap.ArenaAllocator,
    flops: []FlopReset,

    pub fn deinit(self: *View) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }
};

// One backward walk per reset bit with a shared memo: each bit
// resolves once, so tracing stays linear in design size.
pub const HintPolarities = std.StringHashMapUnmanaged(Polarity);

pub fn assign(
    parent: std.mem.Allocator,
    mod: *const ir.types.Module,
    clock_asg: *const clock.trace.Assignment,
    hint_polarities: ?*const HintPolarities,
) error{OutOfMemory}!View {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();

    var by_cell = std.AutoHashMapUnmanaged(usize, clock.trace.Domain){};
    for (clock_asg.flops) |f| try by_cell.put(alloc, f.cell, f.domain);

    var memo = std.AutoHashMapUnmanaged(u32, Resolved){};
    var active = std.AutoHashMapUnmanaged(u32, void){};
    var flops: std.ArrayListUnmanaged(FlopReset) = .empty;
    var w = Walker{ .mod = mod, .alloc = alloc, .memo = &memo, .active = &active, .hints = hint_polarities };
    for (mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type)) continue;
        var async: std.ArrayListUnmanaged(AsyncReset) = .empty;
        if (cells.resetPins(c.type)) |rp| {
            for (rp.async) |ap| {
                // Table pins a cell lacks are skipped: a wrong guess
                // degrades to a missing pin, never a wrong walk.
                const bits = c.portBits(ap.pin) orelse continue;
                const res = try w.resolveBits(bits);
                const pol = w.pinPolarity(c, ap, res);
                var notes: std.ArrayListUnmanaged([]const u8) = .empty;
                for (res.notes) |n| try notes.append(alloc, n);
                if (pol.note) |n| try notes.append(alloc, try alloc.dupe(u8, n));
                try async.append(alloc, .{
                    .pin = try alloc.dupe(u8, ap.pin),
                    .origin = res.origin,
                    .ref = try alloc.dupe(u8, res.ref),
                    .flips = res.flips,
                    .polarity = pol.value,
                    .notes = try notes.toOwnedSlice(alloc),
                });
            }
        }
        try flops.append(alloc, .{
            .cell = ci,
            .clock = try w.dupeDomain(by_cell.get(ci)),
            .async = try async.toOwnedSlice(alloc),
            .sync = try w.detectSync(c),
        });
    }
    return .{ .backing = backing, .flops = try flops.toOwnedSlice(alloc) };
}

const Resolved = struct {
    origin: Origin,
    ref: []const u8,
    flips: u32,
    notes: [][]const u8,
};

const Walker = struct {
    mod: *const ir.types.Module,
    alloc: std.mem.Allocator,
    memo: *std.AutoHashMapUnmanaged(u32, Resolved),
    active: *std.AutoHashMapUnmanaged(u32, void),
    hints: ?*const HintPolarities,

    // A reset bus must agree with itself; disagreement is broken
    // input, reported as unknown rather than picked arbitrarily.
    fn resolveBits(w: *Walker, list: []const ir.bits.Bit) error{OutOfMemory}!Resolved {
        var first: ?Resolved = null;
        for (list) |b| {
            // Tied resets are common (and meaningful), unlike tied
            // clocks: constants resolve instead of being skipped.
            const r = if (b == .sig) try w.resolveBit(b.sig) else try w.resolved(.constant, constName(b), 0, &.{});
            if (first == null) {
                first = r;
            } else if (first.?.origin != r.origin or !std.mem.eql(u8, first.?.ref, r.ref) or first.?.flips != r.flips) {
                return w.resolved(.unknown, "", 0, &.{"reset bits disagree"});
            }
        }
        return first orelse w.resolved(.unknown, "", 0, &.{"unconnected reset"});
    }

    fn resolveBit(w: *Walker, bit: u32) error{OutOfMemory}!Resolved {
        if (w.memo.get(bit)) |r| return r;
        // Active marks the current descent: revisiting one means a
        // combinational loop, which has no meaningful origin.
        if (w.active.contains(bit)) return w.resolved(.unknown, "", 0, &.{"reset-path loop"});
        const drv = w.mod.driver_of.get(bit) orelse return w.resolved(.unknown, "", 0, &.{"undriven reset"});
        try w.active.put(w.alloc, bit, {});
        const res = if (drv.cell) |ci| try w.throughCell(ci) else try w.resolved(.port, drv.port, 0, &.{});
        _ = w.active.remove(bit);
        try w.memo.put(w.alloc, bit, res);
        return res;
    }

    fn throughCell(w: *Walker, ci: usize) error{OutOfMemory}!Resolved {
        const c = w.mod.cells[ci];
        if (clock.cells.isTransparent(c.type)) return w.throughTransparent(c);
        if (cells.muxFollowStatic(c.type)) |follow| return w.throughMux(c, follow);
        if (clock.cells.isSequential(c.type)) return w.resolved(.flop, c.name, 0, &.{});
        if (c.blackbox) return w.resolved(.unknown, "", 0, &.{"blackbox-driven reset"});
        return w.resolved(.comb, c.name, 0, &.{});
    }

    // Buffers pass resets through; only inverters flip polarity.
    fn throughTransparent(w: *Walker, c: ir.types.Cell) error{OutOfMemory}!Resolved {
        var inputs: std.ArrayListUnmanaged(ir.bits.Bit) = .empty;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| try inputs.append(w.alloc, b);
        }
        var res = try w.resolveBits(inputs.items);
        if (clock.cells.isInverting(c.type)) res.flips += 1;
        return res;
    }

    fn throughMux(w: *Walker, c: ir.types.Cell, follow_static: bool) error{OutOfMemory}!Resolved {
        const s = c.portBits("S") orelse return w.resolved(.unknown, "", 0, &.{"malformed reset mux"});
        if (follow_static) {
            if (ir.bits.constSel(s)) |sel| {
                const leg = c.portBits(if (sel) "B" else "A") orelse
                    return w.resolved(.unknown, "", 0, &.{"malformed reset mux"});
                var res = try w.resolveBits(leg);
                const note = try std.fmt.allocPrint(
                    w.alloc,
                    "reset mux static select {s}",
                    .{if (sel) "B" else "A"},
                );
                const notes = try w.alloc.alloc([]const u8, res.notes.len + 1);
                @memcpy(notes[0..res.notes.len], res.notes);
                notes[res.notes.len] = note;
                res.notes = notes;
                return res;
            }
        }
        return w.resolved(.mux, c.name, 0, &.{"reset mux select not followed"});
    }

    fn detectSync(w: *Walker, c: ir.types.Cell) error{OutOfMemory}!SyncReset {
        if (cells.resetPins(c.type)) |rp| {
            for (rp.sync) |sp| {
                if (c.portBits(sp)) |bits| {
                    const res = try w.resolveBits(bits);
                    return .{
                        .kind = .pin,
                        .ref = try w.alloc.dupe(u8, sp),
                        .origin = res.origin,
                        .origin_ref = try w.alloc.dupe(u8, res.ref),
                        .notes = try w.dupeNotes(res.notes),
                    };
                }
            }
        }
        const d = c.portBits("D") orelse return SyncReset{ .kind = .none, .ref = "", .origin = .unknown, .origin_ref = "", .notes = &.{} };
        var saw_pmux = false;
        for (d) |b| {
            if (b != .sig) continue;
            const drv = w.mod.driver_of.get(b.sig) orelse continue;
            const dci = drv.cell orelse continue;
            const m = w.mod.cells[dci];
            if (std.mem.eql(u8, m.type, "$pmux")) saw_pmux = true;
            if (isSyncMux(m)) {
                const s = m.portBits("S") orelse return SyncReset{ .kind = .mux, .ref = try w.alloc.dupe(u8, m.name), .origin = .unknown, .origin_ref = "", .mux = dci, .notes = try w.dupeNotes(&.{"reset mux without select"}) };
                const res = try w.resolveBits(s);
                return .{
                    .kind = .mux,
                    .ref = try w.alloc.dupe(u8, m.name),
                    .origin = res.origin,
                    .origin_ref = try w.alloc.dupe(u8, res.ref),
                    .mux = dci,
                    .notes = try w.dupeNotes(res.notes),
                };
            }
        }
        if (saw_pmux) return SyncReset{ .kind = .none, .ref = "", .origin = .unknown, .origin_ref = "", .notes = try w.dupeNotes(&.{"unhandled $pmux on D"}) };
        return SyncReset{ .kind = .none, .ref = "", .origin = .unknown, .origin_ref = "", .notes = &.{} };
    }

    const PinPolarity = struct { value: Polarity, note: ?[]const u8 };

    // Hint (external file) beats attribute (user promise on the
    // port) beats param (synthesis truth on the pin); each upset
    // is noted, matching the reference reconciliation.
    fn pinPolarity(w: *Walker, c: ir.types.Cell, ap: cells.AsyncPin, res: Resolved) PinPolarity {
        const param = paramPolarity(c, ap.polarity_param);
        if (res.origin == .port) {
            if (w.hints) |h| {
                if (h.get(res.ref)) |hint| {
                    if (param) |p| {
                        if (p != hint) return .{ .value = hint, .note = "polarity hint overrides param" };
                    }
                    return .{ .value = hint, .note = null };
                }
            }
        }
        var attr: ?Polarity = null;
        if (res.origin == .port) {
            if (w.mod.netnames.get(res.ref)) |nn| {
                attr = netnamePolarity(nn);
            }
        }
        if (attr) |a| {
            const eff = if (res.flips % 2 == 1) flip(a) else a;
            if (param) |p| {
                if (p != eff) return .{ .value = eff, .note = "polarity attribute overrides param" };
            }
            return .{ .value = eff, .note = null };
        }
        if (param) |p| return .{ .value = p, .note = null };
        return .{ .value = .unknown, .note = "polarity unknown" };
    }

    fn dupeDomain(w: *Walker, dom: ?clock.trace.Domain) error{OutOfMemory}!clock.trace.Domain {
        const d = dom orelse return .{
            .name = try w.alloc.dupe(u8, "unknown"),
            .root = try w.alloc.dupe(u8, ""),
            .notes = try w.dupeNotes(&.{"flop missing from clock assignment"}),
            .legs = try w.dupeNotes(&.{"unknown"}),
            .sels = &.{},
            .muxes = &.{},
        };
        const sels = try w.alloc.alloc(clock.trace.LegSel, d.sels.len);
        for (d.sels, 0..) |s, i| {
            sels[i] = .{
                .mux = s.mux,
                .side = s.side,
                .gate = if (s.gate) |g| .{
                    .cell = g.cell,
                    .pin = try w.alloc.dupe(u8, g.pin),
                    .bit = g.bit,
                } else null,
                .sel_dom = try w.alloc.dupe(u8, s.sel_dom),
            };
        }
        return .{
            .name = try w.alloc.dupe(u8, d.name),
            .root = try w.alloc.dupe(u8, d.root),
            .notes = try w.dupeNotes(d.notes),
            .legs = try w.dupeNotes(d.legs),
            .sels = sels,
            .muxes = try w.alloc.dupe(usize, d.muxes),
        };
    }

    fn resolved(w: *Walker, origin: Origin, ref: []const u8, flips: u32, notes: []const []const u8) error{OutOfMemory}!Resolved {
        return .{
            .origin = origin,
            .ref = ref,
            .flips = flips,
            .notes = try w.dupeNotes(notes),
        };
    }

    fn dupeNotes(w: *Walker, in: []const []const u8) error{OutOfMemory}![][]const u8 {
        const out = try w.alloc.alloc([]const u8, in.len);
        for (in, 0..) |n, i| out[i] = try w.alloc.dupe(u8, n);
        return out;
    }
};

fn constName(b: ir.bits.Bit) []const u8 {
    return switch (b) {
        .zero => "0",
        .one => "1",
        .x => "x",
        .z => "z",
        .sig => unreachable,
    };
}

// Polarity params are 1-bit values in 32-char strings ('1' and
// '000...01' both occur); the value sits in the last char.
fn paramPolarity(c: ir.types.Cell, want: []const u8) ?Polarity {
    for (c.params) |p| {
        if (!std.mem.eql(u8, p.name, want)) continue;
        switch (p.value) {
            .int => |i| {
                if (i == 1) return .high;
                if (i == 0) return .low;
                return null;
            },
            .str => |s| {
                if (s.len == 0) return null;
                const last = s[s.len - 1];
                if (last == '1') return .high;
                if (last == '0') return .low;
                return null;
            },
        }
    }
    return null;
}

// Port-level declaration, matching the reference: case-insensitive
// high/low, malformed values silently ignored. External hint files
// take precedence over attributes where both exist.
fn netnamePolarity(nn: ir.types.Netname) ?Polarity {
    for (nn.attrs) |a| {
        if (!std.mem.eql(u8, a.name, "reset_polarity")) continue;
        if (a.value != .str) continue;
        if (std.ascii.eqlIgnoreCase(a.value.str, "high")) return .high;
        if (std.ascii.eqlIgnoreCase(a.value.str, "low")) return .low;
        return null;
    }
    return null;
}

fn flip(p: Polarity) Polarity {
    return switch (p) {
        .high => .low,
        .low => .high,
        .unknown => .unknown,
    };
}

// A sync-reset mux switches live data against a 0/1 leg by dynamic
// select. Enable masks and don't-care muxes are ordinary logic.
fn isSyncMux(m: ir.types.Cell) bool {
    if (!std.mem.eql(u8, m.type, "$mux")) return false;
    const s = m.portBits("S") orelse return false;
    if (ir.bits.constSel(s) != null) return false;
    const a = m.portBits("A") orelse return false;
    const b = m.portBits("B") orelse return false;
    const a_const = ir.bits.is01Const(a);
    const b_const = ir.bits.is01Const(b);
    if (a_const == b_const) return false;
    const data = if (a_const) b else a;
    for (data) |bit| if (bit == .sig) return true;
    return false;
}
