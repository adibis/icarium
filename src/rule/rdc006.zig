const std = @import("std");
const bus = @import("bus.zig");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "RDC-006",
    .severity = .warn,
    .title = "Muxed async reset without a local synchronizer",
    .doc =
    \\A flop's async reset is driven directly by a mux: selection
    \\is explicit, but the selected leg still deasserts async to
    \\the consumer clock. Pipe the mux through a 2FF reset
    \\synchronizer in the consumer domain. Warning, not error:
    \\the block may legitimately consume an upstream-synced reset.
    ,
    .honors = &.{"reset_sync"},
    .check_all = checkAll,
};

// One finding per flop whose ARST lands on a $mux/$pmux: the
// explicit-selection shape RDC-005 exempts still deasserts
// async. Chain stages and user marks pass; syncing is their job.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    // Walks die per flop: reset cones span the design, and one
    // retained walk per flop exhausts memory at full-chip scale.
    var backing = ctx.table.workArena();
    defer backing.deinit();
    var scratch = std.heap.ArenaAllocator.init(backing.allocator());
    defer scratch.deinit();
    for (ctx.mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        if (ctx.reset_syncs.isMember(c.name)) continue;
        const arst = bus.portBits(c, "ARST") orelse continue;
        if (arst.len == 0 or arst[0] != .sig) continue;
        const drv = ctx.mod.driver_of.get(arst[0].sig) orelse continue;
        const di = drv.cell orelse continue;
        const dc = ctx.mod.cells[di];
        if (!std.mem.eql(u8, dc.type, "$mux") and !std.mem.eql(u8, dc.type, "$pmux")) continue;
        _ = scratch.reset(.retain_capacity);
        const phrase = try sourcesPhrase(ctx, scratch.allocator(), dc);
        const message = try std.fmt.allocPrint(ctx.tmp,
            "muxed async reset without local synchronizer: flop '{s}' reset pin is driven by a {s} selecting between {s}. The mux makes source selection explicit (why RDC-005 stays silent), but the selected reset's deassertion edge is still asynchronous to this flop's clock. Add a 2FF reset synchronizer in the consumer clock domain between the mux and this flop's reset pin.",
            .{ c.name, dc.type, phrase });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = ctx.mod.cells[ci].name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

// Data legs only: the select is control, not a reset source,
// and naming it one confuses the fix.
fn sourcesPhrase(ctx: *context.Context, alloc: std.mem.Allocator, mux: @import("../ir.zig").types.Cell) error{OutOfMemory}![]const u8 {
    var legs = std.ArrayListUnmanaged(@import("../ir.zig").bits.Bit).empty;
    for ([_][]const u8{ "A", "B" }) |pin| {
        if (bus.portBits(mux, pin)) |bits| try legs.appendSlice(alloc, bits);
    }
    const ports = try context.backwardPortFanin(alloc, ctx.mod, legs.items);
    std.mem.sort([]const u8, ports, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    if (ports.len == 0) return "multiple reset sources";
    var buf = std.ArrayListUnmanaged(u8).empty;
    const head = try std.fmt.allocPrint(ctx.tmp, "{d} reset sources (", .{ports.len});
    try buf.appendSlice(ctx.tmp, head);
    const show = @min(ports.len, 3);
    for (ports[0..show], 0..) |p, i| {
        if (i > 0) try buf.appendSlice(ctx.tmp, ", ");
        try buf.appendSlice(ctx.tmp, p);
    }
    if (ports.len > 3) try buf.appendSlice(ctx.tmp, "...");
    try buf.appendSlice(ctx.tmp, ")");
    return buf.toOwnedSlice(ctx.tmp);
}
