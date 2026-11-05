const std = @import("std");
const ir = @import("../ir.zig");
const reset = @import("../reset.zig");

// User-vetted synchronizer assertions, read off netname wires:
// the attribute sits on the signal, membership on the flop whose
// Q it names. Names match the reference alias sets verbatim.
pub const sync_names = std.StaticStringMap(void).initComptime(.{
    .{ "cdc_sync", {} },
    .{ "synchronizer", {} },
    .{ "async_reg", {} },
});

pub const static_names = std.StaticStringMap(void).initComptime(.{
    .{ "cdc_static", {} },
    .{ "quasi_static", {} },
});

pub const handshake_names = std.StaticStringMap(void).initComptime(.{
    .{ "cdc_handshake", {} },
    .{ "req_ack_handshake", {} },
});

pub const gray_names = std.StaticStringMap(void).initComptime(.{
    .{ "cdc_gray", {} },
    .{ "gray_code", {} },
});

pub const glitchless_names = std.StaticStringMap(void).initComptime(.{
    .{ "glitchless_clock_mux", {} },
    .{ "glitchless_mux", {} },
    .{ "glitchfree_clock_mux", {} },
});

pub const reset_sync_names = std.StaticStringMap(void).initComptime(.{
    .{ "reset_sync", {} },
    .{ "reset_synchronizer", {} },
});

pub const reset_polarity_names = std.StaticStringMap(void).initComptime(.{
    .{ "reset_polarity", {} },
});

pub const Marks = struct {
    backing: *std.heap.ArenaAllocator,
    syncs: std.StringHashMapUnmanaged(void),
    statics: std.StringHashMapUnmanaged(void),
    handshakes: std.StringHashMapUnmanaged(void),
    grays: std.StringHashMapUnmanaged(void),
    glitchless_bits: std.AutoHashMapUnmanaged(u32, void),
    reset_syncs: std.StringHashMapUnmanaged(void),
    reset_polarities: std.StringHashMapUnmanaged(reset.trace.Polarity),

    pub fn deinit(self: *Marks) void {
        const parent = self.backing.child_allocator;
        self.backing.deinit();
        parent.destroy(self.backing);
    }

    pub fn hasSync(self: *const Marks, cell_name: []const u8) bool {
        return self.syncs.contains(cell_name);
    }

    pub fn hasStatic(self: *const Marks, cell_name: []const u8) bool {
        return self.statics.contains(cell_name);
    }

    pub fn hasHandshake(self: *const Marks, cell_name: []const u8) bool {
        return self.handshakes.contains(cell_name);
    }

    pub fn hasGray(self: *const Marks, cell_name: []const u8) bool {
        return self.grays.contains(cell_name);
    }

    pub fn glitchlessBit(self: *const Marks, bit: u32) bool {
        return self.glitchless_bits.contains(bit);
    }

    pub fn hasResetSync(self: *const Marks, cell_name: []const u8) bool {
        return self.reset_syncs.contains(cell_name);
    }

    pub fn resetPolarity(self: *const Marks, port: []const u8) ?reset.trace.Polarity {
        return self.reset_polarities.get(port);
    }
};

// Case follows the reference exactly: sync matching is insensitive
// (Xilinx spells ASYNC_REG), the rest are verbatim. The asymmetry
// is inherited, not an oversight.
fn markedBits(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    names: *const std.StaticStringMap(void),
    insensitive: bool,
) error{OutOfMemory}!std.AutoHashMapUnmanaged(u32, void) {
    var out = std.AutoHashMapUnmanaged(u32, void).empty;
    var it = mod.netnames.iterator();
    while (it.next()) |nn| {
        var hit = false;
        for (nn.value_ptr.attrs) |a| {
            if (insensitive) {
                for (names.keys()) |k| {
                    if (std.ascii.eqlIgnoreCase(a.name, k)) {
                        hit = true;
                        break;
                    }
                }
            } else if (names.get(a.name) != null) {
                hit = true;
            }
            if (hit) break;
        }
        if (!hit) continue;
        for (nn.value_ptr.bits) |b| {
            if (b == .sig) try out.put(alloc, b.sig, {});
        }
    }
    return out;
}

pub fn collect(parent: std.mem.Allocator, mod: *const ir.types.Module) error{OutOfMemory}!Marks {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();

    const sync_bits = try markedBits(alloc, mod, &sync_names, true);
    const static_bits = try markedBits(alloc, mod, &static_names, false);
    const handshake_bits = try markedBits(alloc, mod, &handshake_names, false);
    const gray_bits = try markedBits(alloc, mod, &gray_names, false);
    const glitchless_bits = try markedBits(alloc, mod, &glitchless_names, false);
    const reset_sync_bits = try markedBits(alloc, mod, &reset_sync_names, false);

    var syncs = std.StringHashMapUnmanaged(void).empty;
    var statics = std.StringHashMapUnmanaged(void).empty;
    var handshakes = std.StringHashMapUnmanaged(void).empty;
    var grays = std.StringHashMapUnmanaged(void).empty;
    var reset_syncs = std.StringHashMapUnmanaged(void).empty;
    for (mod.cells) |c| {
        const q = portBits(c, "Q") orelse continue;
        for (q) |b| {
            if (b != .sig) continue;
            if (sync_bits.contains(b.sig)) try syncs.put(alloc, c.name, {});
            if (static_bits.contains(b.sig)) try statics.put(alloc, c.name, {});
            if (handshake_bits.contains(b.sig)) try handshakes.put(alloc, c.name, {});
            if (gray_bits.contains(b.sig)) try grays.put(alloc, c.name, {});
            if (reset_sync_bits.contains(b.sig)) try reset_syncs.put(alloc, c.name, {});
        }
    }
    return .{
        .backing = backing,
        .syncs = syncs,
        .statics = statics,
        .handshakes = handshakes,
        .grays = grays,
        .glitchless_bits = glitchless_bits,
        .reset_syncs = reset_syncs,
        .reset_polarities = try polarityOverrides(alloc, mod),
    };
}

// Port-level reset polarity declarations: only netnames that ARE
// top-level input ports count, and only high/low values decode.
// Anything else stays out rather than failing the run.
fn polarityOverrides(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
) error{OutOfMemory}!std.StringHashMapUnmanaged(reset.trace.Polarity) {
    var out = std.StringHashMapUnmanaged(reset.trace.Polarity).empty;
    var it = mod.netnames.iterator();
    while (it.next()) |nn| {
        if (!isInputPort(mod, nn.key_ptr.*)) continue;
        for (nn.value_ptr.attrs) |a| {
            if (reset_polarity_names.get(a.name) == null) continue;
            if (a.value != .str) continue;
            const v = std.mem.trim(u8, a.value.str, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(v, "high")) try out.put(alloc, nn.key_ptr.*, .high);
            if (std.ascii.eqlIgnoreCase(v, "low")) try out.put(alloc, nn.key_ptr.*, .low);
        }
    }
    return out;
}

fn isInputPort(mod: *const ir.types.Module, name: []const u8) bool {
    for (mod.ports) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.direction == .input;
    }
    return false;
}

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
    }
    return null;
}
