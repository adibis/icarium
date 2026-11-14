const std = @import("std");
const bits = @import("bits.zig");

pub const Dir = enum { input, output, inout };

// Three spellings, fixed by the Yosys schema: resolve them once
// at compile time instead of comparing on every port parsed.
const dirs = std.StaticStringMap(Dir).initComptime(.{
    .{ "input", .input },
    .{ "output", .output },
    .{ "inout", .inout },
});

pub fn dirFromString(s: []const u8) error{BadDirection}!Dir {
    return dirs.get(s) orelse error.BadDirection;
}

pub const Port = struct {
    name: []const u8,
    direction: Dir,
    bits: []bits.Bit,
};

pub const AttrVal = union(enum) { int: i64, str: []const u8 };

pub const Attr = struct {
    name: []const u8,
    value: AttrVal,
};

pub const Cell = struct {
    name: []const u8,
    type: []const u8,
    ports: []Port,
    params: []Attr,
    attrs: []Attr,
    src: ?[]const u8,
    instance_path: [][]const u8,
    blackbox: bool,

    // Linear scan: cells carry few ports, and one method
    // serves every caller.
    pub fn portBits(self: Cell, want: []const u8) ?[]bits.Bit {
        for (self.ports) |p| {
            if (std.mem.eql(u8, p.name, want)) return p.bits;
        }
        return null;
    }
};

pub const ModulePort = struct {
    name: []const u8,
    direction: Dir,
    bits: []bits.Bit,
};

pub const Loc = struct {
    cell: ?usize,
    port: []const u8,
};

pub const Netname = struct {
    bits: []bits.Bit,
    attrs: []Attr,
};

pub const DriverMap = std.AutoHashMapUnmanaged(u32, Loc);
pub const LoadsMap = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(Loc));
pub const NetnameMap = std.StringHashMapUnmanaged(Netname);

pub const Module = struct {
    // Heap-owned: ArenaAllocator captures its own address, so a
    // by-value copy would orphan later allocations from deinit.
    backing: *std.heap.ArenaAllocator,
    name: []const u8,
    cells: []Cell,
    ports: []ModulePort,
    driver_of: DriverMap,
    loads_of: LoadsMap,
    // Netname attributes (reset polarity and friends) live on wires,
    // not cells, so the map survives ingestion for later lookups.
    netnames: NetnameMap,

    pub fn deinit(self: *Module) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }
};
