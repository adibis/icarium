const std = @import("std");
const context = @import("context.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");

pub const rule = registry.Rule{
    .id = "RDC-007",
    .severity = .err,
    .title = "Reset synchronizer chain loads the asserted value",
    .doc =
    \\A reset synchronizer chain whose head D ties to the asserted
    \\value never deasserts: on release it reloads assertion and
    \\holds every downstream consumer in reset forever. Tie the
    \\head D to the deasserted value: 1'b1 for active-low resets.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// One finding per chain per polarity: the head constant must be
// the deasserted value, the inverse of the assertion polarity.
// Non-constant heads carry nothing to compare, so they pass.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    for (ctx.reset_syncs.chains) |ch| {
        const deassert: u8 = if (ch.polarity == .high) '0' else '1';
        const head_d: u8 = switch (ch.head_d) {
            .one => '1',
            .zero => '0',
            else => continue,
        };
        if (head_d == deassert) continue;
        const tail = ctx.mod.cells[ch.flops[0]].name;
        const head = ctx.mod.cells[ch.flops[ch.flops.len - 1]].name;
        const word: []const u8 = if (ch.polarity == .high) "active-high" else "active-low";
        const message = try std.fmt.allocPrint(ctx.alloc,
            "reset-synchronizer chain {s} <- ... <- {s} has its head D tied to '{c}', but the chain's reset is {s} (deasserts on '{c}'). The chain reloads the asserted value on the deassertion edge: its output is a one-shot stuck driving the asserted value forever, and every downstream consumer using {s}.Q as their ARST will never leave reset. Tie the head's D to 1'b{c}.",
            .{ tail, head, head_d, word, deassert, tail, deassert });
        try out.append(ctx.alloc, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = tail,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.alloc);
}
