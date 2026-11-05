const std = @import("std");
const bus = @import("bus.zig");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");
const reset = @import("../reset.zig");

pub const rule = registry.Rule{
    .id = "RDC-004",
    .severity = .err,
    .title = "Async reset driven by combinational logic",
    .doc =
    \\A flop's async reset pin is a comb gate's output fed by flops.
    \\Gate outputs glitch on near-simultaneous input changes, and on
    \\an async reset pin the transient reads as a real assertion.
    \\Register the gate on the consumer clock first.
    ,
    .honors = &.{"reset_sync"},
    .check_all = checkAll,
};

// Async consumers whose reset pin is one hop from a non-Q cell
// output, with flops behind the gate. Pure-port comb stays out:
// ANDed external resets are the user's business, not the tool's.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    for (ctx.mod.cells) |c| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        if (ctx.reset_syncs.isMember(c.name)) continue;
        const ap = reset.cells.canonicalAsyncPin(c) orelse continue;
        const rst = bus.portBits(c, ap.pin) orelse continue;
        if (rst.len == 0 or rst[0] != .sig) continue;
        if (!isCombSource(ctx, rst[0].sig)) continue;
        const fanin = try context.backwardFlopFanin(ctx.alloc, ctx.mod, rst);
        if (fanin.items.len == 0) continue;
        var names = std.ArrayListUnmanaged([]const u8).empty;
        for (fanin.items) |f| try names.append(ctx.alloc, ctx.mod.cells[f].name);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        const desc = try flopDesc(ctx, names.items);
        const message = try std.fmt.allocPrint(ctx.alloc,
            "reset driven by combinational logic: flop {s}'s reset pin is the output of combinational gate(s) fed by flop(s) {s}. Comb-gate outputs can glitch when inputs transition asynchronously, causing spurious reset assertions. Register the comb output on the consumer's clock before using as a reset.",
            .{ c.name, desc });
        try out.append(ctx.alloc, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = c.name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.alloc);
}

// One-hop comb test: a cell output that is neither a flop Q nor
// a top-level port. Untracked drivers read comb too, refusing
// to reason about resets the walker cannot classify.
fn isCombSource(ctx: *context.Context, bit: u32) bool {
    const drv = ctx.mod.driver_of.get(bit) orelse return true;
    if (drv.cell == null) return false;
    return !std.mem.eql(u8, drv.port, "Q");
}

// Three flop names, then an ellipsis: the gate's whole fanin
// fits the message only on small trees.
fn flopDesc(ctx: *context.Context, names: [][]const u8) error{OutOfMemory}![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    const show = @min(names.len, 3);
    for (names[0..show], 0..) |n, i| {
        if (i > 0) try buf.appendSlice(ctx.alloc, ", ");
        try buf.appendSlice(ctx.alloc, n);
    }
    if (names.len > 3) try buf.appendSlice(ctx.alloc, "...");
    return buf.toOwnedSlice(ctx.alloc);
}
