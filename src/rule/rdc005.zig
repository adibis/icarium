const std = @import("std");
const bus = @import("bus.zig");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");
const reset = @import("../reset.zig");

pub const rule = registry.Rule{
    .id = "RDC-005",
    .severity = .err,
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
    for (ctx.mod.cells) |c| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        if (ctx.reset_syncs.isMember(c.name)) continue;
        const ap = reset.cells.canonicalAsyncPin(c) orelse continue;
        const rst = bus.portBits(c, ap.pin) orelse continue;
        if (rst.len == 0) continue;
        const flops = try context.backwardFlopFanin(ctx.alloc, ctx.mod, rst);
        if (flops.items.len > 0) continue;
        const ports = try context.backwardPortFanin(ctx.alloc, ctx.mod, rst);
        if (ports.len < 2) continue;
        std.mem.sort([]const u8, ports, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        const desc = try std.mem.join(ctx.alloc, ", ", ports);
        const message = try std.fmt.allocPrint(ctx.alloc,
            "reset from multiple independent sources: flop {s}'s async reset is driven by combinational logic over {d} independent top-level reset ports ({s}), with no flops in the reset path. Independent reset sources release at different times; the consumer's effective release edge is undefined. Qualify the sources through a single reset tree or a reset synchroniser.",
            .{ c.name, ports.len, desc });
        try out.append(ctx.alloc, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = c.name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.alloc);
}
