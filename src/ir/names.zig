// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const bits = @import("bits.zig");
const types = @import("types.zig");

// RTL names for the cells findings point at. Yosys names a flop
// after the pass that made it ($procdff$9), but `proc` names the
// flop's next-state net after the register the designer wrote:
// `$0\q_reg[3:0]`, or `$flatten\u_a.$0\q_reg[3:0]` once flattened.
// That net names the flop exactly. Front ends without proc's nets
// fall back to the public net on the cell's output, preferring one
// declared in the cell's own scope.
pub const Names = std.AutoHashMapUnmanaged(usize, []const u8);

// Only the cells asked for: on a full chip the findings touch far
// fewer bits than the netlist holds.
pub fn build(alloc: std.mem.Allocator, mod: *const types.Module, cells: []const usize) error{OutOfMemory}!Names {
    var want_d = std.AutoHashMapUnmanaged(u32, void).empty;
    var want_out = std.AutoHashMapUnmanaged(u32, void).empty;
    for (cells) |ci| {
        const c = mod.cells[ci];
        if (!needsName(c)) continue;
        if (firstSig(c.portBits("D"))) |b| if (c.portBits("Q") != null) try want_d.put(alloc, b, {});
        if (firstSig(outBits(c))) |b| try want_out.put(alloc, b, {});
    }

    // Next-state nets by first D bit, public nets by each wanted bit.
    var next = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(Next)).empty;
    var public = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged([]const u8)).empty;
    var it = mod.netnames.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const nn = e.value_ptr.*;
        if (try regOfNextState(alloc, name)) |reg| {
            const b = firstSig(nn.bits) orelse continue;
            if (!want_d.contains(b)) continue;
            const slot = try next.getOrPut(alloc, b);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(alloc, .{ .reg = reg, .bits = nn.bits });
            continue;
        }
        if (hidden(name)) continue;
        for (nn.bits) |bit| {
            if (bit != .sig or !want_out.contains(bit.sig)) continue;
            const slot = try public.getOrPut(alloc, bit.sig);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(alloc, name);
        }
    }

    var out = Names.empty;
    for (cells) |ci| {
        if (out.contains(ci)) continue;
        const c = mod.cells[ci];
        if (!needsName(c)) continue;
        const o = outBits(c) orelse continue;
        if (try fromNextState(alloc, mod, &next, c, o)) |n| {
            try out.put(alloc, ci, n);
        } else if (try fromOutput(alloc, mod, &public, c, o)) |n| {
            try out.put(alloc, ci, n);
        }
    }
    return out;
}

const Next = struct { reg: []const u8, bits: []const bits.Bit };

// A cell whose name is already RTL (an instance, a blackbox) keeps
// it; only pass-generated `$` names need translating. Their leaf can
// hold a source path, so the test is on the name, then the leaf.
fn needsName(c: types.Cell) bool {
    if (c.blackbox) return false;
    if (std.mem.startsWith(u8, c.name, "$")) return true;
    const leaf = if (std.mem.lastIndexOfScalar(u8, c.name, '.')) |d| c.name[d + 1 ..] else c.name;
    return std.mem.startsWith(u8, leaf, "$");
}

fn outBits(c: types.Cell) ?[]bits.Bit {
    if (c.portBits("Q")) |q| return q;
    for (c.ports) |p| if (p.direction == .output) return p.bits;
    return null;
}

fn firstSig(bs: ?[]const bits.Bit) ?u32 {
    const s = bs orelse return null;
    if (s.len == 0 or s[0] != .sig) return null;
    return s[0].sig;
}

fn hidden(name: []const u8) bool {
    const leaf = if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| name[d + 1 ..] else name;
    return name.len == 0 or name[0] == '$' or leaf.len == 0 or leaf[0] == '$';
}

// `[$flatten\][\]a.[\]b.$0\reg[hi:lo]` -> "a.b.reg"; null for any
// other name. The range is dropped: the register's own net says
// which bits the flop covers.
fn regOfNextState(alloc: std.mem.Allocator, name: []const u8) error{OutOfMemory}!?[]const u8 {
    const mark = "$0\\";
    const at = std.mem.indexOf(u8, name, mark) orelse return null;
    const tail = name[at + mark.len ..];
    const reg = tail[0 .. std.mem.lastIndexOfScalar(u8, tail, '[') orelse tail.len];
    if (reg.len == 0) return null;
    var scope = name[0..at];
    const flat = "$flatten\\";
    if (std.mem.startsWith(u8, scope, flat)) scope = scope[flat.len..];
    if (scope.len > 0 and scope[scope.len - 1] != '.') return null;
    return try joinScope(alloc, scope, reg);
}

fn joinScope(alloc: std.mem.Allocator, scope: []const u8, leaf: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var seg_start = true;
    for (scope) |ch| {
        if (seg_start and ch == '\\') {
            seg_start = false;
            continue;
        }
        seg_start = ch == '.';
        try out.append(alloc, ch);
    }
    try out.appendSlice(alloc, leaf);
    return out.toOwnedSlice(alloc);
}

fn fromNextState(
    alloc: std.mem.Allocator,
    mod: *const types.Module,
    next: *const std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(Next)),
    c: types.Cell,
    q: []const bits.Bit,
) error{OutOfMemory}!?[]const u8 {
    if (c.portBits("Q") == null) return null;
    const d = c.portBits("D") orelse return null;
    const b = firstSig(d) orelse return null;
    const list = next.get(b) orelse return null;
    // Two flops sampling one net share its next-state bits; the
    // register's own net must also carry this flop's Q to count.
    var best: ?[]const u8 = null;
    for (list.items) |n| {
        if (!sameBits(n.bits, d)) continue;
        const reg = mod.netnames.get(n.reg) orelse continue;
        const at = position(reg.bits, q) orelse continue;
        const shown = try render(alloc, n.reg, reg, at, q.len);
        if (best == null or std.mem.lessThan(u8, shown, best.?)) best = shown;
    }
    return best;
}

fn fromOutput(
    alloc: std.mem.Allocator,
    mod: *const types.Module,
    public: *const std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged([]const u8)),
    c: types.Cell,
    o: []const bits.Bit,
) error{OutOfMemory}!?[]const u8 {
    const b = firstSig(o) orelse return null;
    const list = public.get(b) orelse return null;
    var best: ?[]const u8 = null;
    var best_rank: Rank = undefined;
    for (list.items) |name| {
        const nn = mod.netnames.get(name) orelse continue;
        if (position(nn.bits, o) == null) continue;
        const r = rank(c, name);
        if (best == null or r.better(best_rank) or (r.eql(best_rank) and std.mem.lessThan(u8, name, best.?))) {
            best = name;
            best_rank = r;
        }
    }
    const name = best orelse return null;
    const nn = mod.netnames.get(name).?;
    return try render(alloc, name, nn, position(nn.bits, o).?, o.len);
}

// The cell's own scope first (a submodule's register, not the
// parent wire it drives), then the shortest name.
const Rank = struct {
    own_scope: bool,
    len: usize,

    fn better(a: Rank, b: Rank) bool {
        if (a.own_scope != b.own_scope) return a.own_scope;
        return a.len < b.len;
    }

    fn eql(a: Rank, b: Rank) bool {
        return a.own_scope == b.own_scope and a.len == b.len;
    }
};

fn rank(c: types.Cell, name: []const u8) Rank {
    const scope = if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| name[0..d] else "";
    return .{ .own_scope = sameScope(c.instance_path, scope), .len = name.len };
}

fn sameScope(path: []const []const u8, scope: []const u8) bool {
    var rest = scope;
    for (path, 0..) |seg, k| {
        if (k > 0) {
            if (rest.len == 0 or rest[0] != '.') return false;
            rest = rest[1..];
        }
        if (!std.mem.startsWith(u8, rest, seg)) return false;
        rest = rest[seg.len..];
    }
    return rest.len == 0;
}

// Where `want` sits as a run inside `have`, if it does.
fn position(have: []const bits.Bit, want: []const bits.Bit) ?usize {
    if (want.len == 0 or want.len > have.len) return null;
    var i: usize = 0;
    while (i + want.len <= have.len) : (i += 1) {
        if (sameBits(have[i .. i + want.len], want)) return i;
    }
    return null;
}

fn sameBits(a: []const bits.Bit, b: []const bits.Bit) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

fn render(alloc: std.mem.Allocator, name: []const u8, nn: types.Netname, at: usize, len: usize) error{OutOfMemory}![]const u8 {
    if (at == 0 and len == nn.bits.len) return alloc.dupe(u8, name);
    // Most significant first, as the declaration reads.
    const lsb = index(nn, at);
    const msb = index(nn, at + len - 1);
    if (len == 1) return std.fmt.allocPrint(alloc, "{s}[{d}]", .{ name, lsb });
    return std.fmt.allocPrint(alloc, "{s}[{d}:{d}]", .{ name, msb, lsb });
}

fn index(nn: types.Netname, pos: usize) i64 {
    const p: i64 = @intCast(pos);
    if (nn.upto) return nn.offset + @as(i64, @intCast(nn.bits.len)) - 1 - p;
    return nn.offset + p;
}
