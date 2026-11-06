const std = @import("std");
const bus = @import("bus.zig");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");
const reset = @import("../reset.zig");

pub const rule = registry.Rule{
    .id = "RDC-005",
    .severity = .warn,
    .title = "Async reset from multiple independent sources",
    .doc =
    \\A flop's async reset combines two or more top-level ports with
    \\no flop behind the gate. Independent board sources release at
    \\independent times; the consumer's release edge is undefined.
    \\Qualify the sources through one reset tree.
    ,
    .honors = &.{"reset_sync"},
    .check_all = checkAll,
};

// Async consumers whose reset pin reaches two or more input
// ports with no flop in the fanin. Flopped trees belong to
// RDC-004; single ports are clean distribution.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    // Walks die per flop: reset cones span the design, and one
    // retained walk per flop buried the full-top once pass.
    var backing = ctx.table.workArena();
    defer backing.deinit();
    var scratch = std.heap.ArenaAllocator.init(backing.allocator());
    defer scratch.deinit();
    for (ctx.mod.cells) |c| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        if (ctx.reset_syncs.isMember(c.name)) continue;
        const ap = reset.cells.canonicalAsyncPin(c) orelse continue;
        const rst = bus.portBits(c, ap.pin) orelse continue;
        if (rst.len == 0) continue;
        if (muxDriven(ctx, rst)) continue;
        _ = scratch.reset(.retain_capacity);
        const alloc = scratch.allocator();
        const flops = try context.backwardFlopFanin(alloc, ctx.mod, rst);
        if (flops.items.len > 0) continue;
        const ports = try context.backwardPortFanin(alloc, ctx.mod, rst);
        if (ports.len < 2) continue;
        std.mem.sort([]const u8, ports, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        const desc = try std.mem.join(ctx.tmp, ", ", ports);
        const message = try std.fmt.allocPrint(ctx.tmp, "reset from multiple independent sources: flop {s}'s async reset is driven by combinational logic over {d} independent top-level reset ports ({s}), with no flops in the reset path. Independent reset sources release at different times; the consumer's effective release edge is undefined. Qualify the sources through a single reset tree or a reset synchroniser.", .{ c.name, ports.len, desc });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = c.name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

// Explicit selection excuses the crowd: a mux-driven reset is
// the user's declared intent, RDC-006's territory, not this one.
fn muxDriven(ctx: *context.Context, rst: []@import("../ir.zig").bits.Bit) bool {
    for (rst) |b| {
        if (b != .sig) continue;
        const drv = ctx.mod.driver_of.get(b.sig) orelse continue;
        const di = drv.cell orelse continue;
        const t = ctx.mod.cells[di].type;
        if (std.mem.eql(u8, t, "$mux") or std.mem.eql(u8, t, "$pmux")) return true;
    }
    return false;
}
