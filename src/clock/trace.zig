const std = @import("std");
const cells = @import("cells.zig");
const ir = @import("../ir.zig");
const sdc = @import("../sdc.zig");

pub const Domain = struct {
    name: []const u8,
    root: []const u8,
    notes: [][]const u8,
};

pub const FlopDomain = struct {
    cell: usize,
    domain: Domain,
};

pub const Assignment = struct {
    // Heap-owned, matching Module: copying a live arena orphans
    // later allocations from deinit (see ir/types.zig).
    backing: *std.heap.ArenaAllocator,
    flops: []FlopDomain,

    pub fn deinit(self: *Assignment) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }
};

// One backward walk per CLK bit with a shared memo: each bit
// resolves once, so tracing stays linear in design size.
pub fn assign(parent: std.mem.Allocator, mod: *const ir.types.Module, model: *const sdc.model.Model) error{OutOfMemory}!Assignment {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();

    var memo = std.AutoHashMapUnmanaged(u32, Domain){};
    var active = std.AutoHashMapUnmanaged(u32, void){};
    var flops: std.ArrayListUnmanaged(FlopDomain) = .empty;
    var w = Walker{ .mod = mod, .model = model, .alloc = alloc, .memo = &memo, .active = &active };
    for (mod.cells, 0..) |c, ci| {
        if (!cells.isSequential(c.type)) continue;
        const dom = if (clkBits(c)) |clk|
            try w.resolveBits(clk)
        else
            try w.make("unknown", "", &.{"no CLK pin"});
        try flops.append(alloc, .{ .cell = ci, .domain = dom });
    }
    return .{ .backing = backing, .flops = try flops.toOwnedSlice(alloc) };
}

fn clkBits(c: ir.types.Cell) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, cells.clk_pin)) return p.bits;
    }
    return null;
}

const Walker = struct {
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    alloc: std.mem.Allocator,
    memo: *std.AutoHashMapUnmanaged(u32, Domain),
    active: *std.AutoHashMapUnmanaged(u32, void),

    // A clock bus must agree with itself; disagreement is broken
    // input, reported as unknown rather than picked arbitrarily.
    fn resolveBits(w: *Walker, list: []const ir.bits.Bit) error{OutOfMemory}!Domain {
        var first: ?Domain = null;
        for (list) |b| {
            if (b != .sig) continue;
            const d = try w.resolveBit(b.sig);
            if (first == null) {
                first = d;
            } else if (!std.mem.eql(u8, first.?.name, d.name)) {
                return w.make("unknown", "", &.{"clock bits disagree"});
            }
        }
        return first orelse w.make("unknown", "", &.{"unconnected clock"});
    }

    fn resolveBit(w: *Walker, bit: u32) error{OutOfMemory}!Domain {
        if (w.memo.get(bit)) |d| return d;
        // Active marks the current descent: revisiting one means a
        // combinational loop, which has no meaningful domain.
        if (w.active.contains(bit)) return w.make("unknown", "", &.{"clock-path loop"});
        const drv = w.mod.driver_of.get(bit) orelse return w.make("unknown", "", &.{"undriven clock"});
        try w.active.put(w.alloc, bit, {});
        const dom = if (drv.cell) |ci| try w.throughCell(ci) else try w.throughPort(drv.port);
        _ = w.active.remove(bit);
        try w.memo.put(w.alloc, bit, dom);
        return dom;
    }

    fn throughPort(w: *Walker, port: []const u8) error{OutOfMemory}!Domain {
        if (sdc.model.rootClock(w.model, port)) |c| return w.make(c, port, &.{});
        if (w.model.clocks.contains(port)) return w.make(port, port, &.{});
        // Undeclared roots still get a domain: downstream analysis
        // continues, and CDC-021 judges the missing declaration.
        return .{
            .name = try std.fmt.allocPrint(w.alloc, "port:{s}", .{port}),
            .root = try w.alloc.dupe(u8, port),
            .notes = try w.dupeNotes(&.{"undeclared clock root"}),
        };
    }

    fn throughCell(w: *Walker, ci: usize) error{OutOfMemory}!Domain {
        const c = w.mod.cells[ci];
        if (cells.isTransparent(c.type)) return w.throughTransparent(c);
        if (cells.isSequential(c.type)) return w.make("unknown", "", &.{"sequential clock driver"});
        if (c.blackbox) return w.make("unknown", "", &.{"blackbox-driven clock"});
        const why = try std.fmt.allocPrint(w.alloc, "unhandled {s} on clock path", .{c.type});
        defer w.alloc.free(why);
        return w.make("unknown", "", &.{why});
    }

    // Transparent cells pass the domain through; the inversion note
    // stays so polarity-sensitive rules need no re-walk.
    fn throughTransparent(w: *Walker, c: ir.types.Cell) error{OutOfMemory}!Domain {
        var inputs: std.ArrayListUnmanaged(ir.bits.Bit) = .empty;
        for (c.ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| try inputs.append(w.alloc, b);
        }
        const dom = try w.resolveBits(inputs.items);
        if (std.mem.eql(u8, dom.name, "unknown")) return dom;
        return w.withNote(dom, "inverted clock");
    }

    fn make(w: *Walker, name: []const u8, root: []const u8, notes: []const []const u8) error{OutOfMemory}!Domain {
        return .{
            .name = try w.alloc.dupe(u8, name),
            .root = try w.alloc.dupe(u8, root),
            .notes = try w.dupeNotes(notes),
        };
    }

    // Every string owned: the assignment outlives nothing it borrows.
    fn dupeNotes(w: *Walker, in: []const []const u8) error{OutOfMemory}![][]const u8 {
        const out = try w.alloc.alloc([]const u8, in.len);
        for (in, 0..) |n, i| out[i] = try w.alloc.dupe(u8, n);
        return out;
    }

    fn withNote(w: *Walker, dom: Domain, text: []const u8) error{OutOfMemory}!Domain {
        const out = try w.alloc.alloc([]const u8, dom.notes.len + 1);
        @memcpy(out[0..dom.notes.len], dom.notes);
        out[dom.notes.len] = try w.alloc.dupe(u8, text);
        return .{ .name = dom.name, .root = dom.root, .notes = out };
    }
};
