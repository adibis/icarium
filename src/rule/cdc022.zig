const std = @import("std");
const context = @import("context.zig");
const finding = @import("finding.zig");
const registry = @import("registry.zig");
const sync = @import("../sync.zig");

pub const rule = registry.Rule{
    .id = "CDC-022",
    .severity = .warn,
    .title = "Synchronizer primitive shallower than required depth",
    .doc =
    \\A CDC macro carries its stage count as a parameter, not a flop
    \\chain, so CDC-002 cannot see it. Under a project minimum the
    \\instance reads short. Raise the parameter or lower the bar.
    ,
    .honors = &.{},
    .check_all = checkAll,
};

// Every recognized macro instance, sorted by name; every depth
// parameter below the project minimum reports. XPM absences
// read the documented default; site macros without the
// parameter stay out, having no default to assume.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    var insts = std.ArrayListUnmanaged(usize).empty;
    for (ctx.mod.cells, 0..) |c, ci| {
        if (sync.primitives.isSyncPrimitive(c.type, ctx.cfg.sync_primitives)) try insts.append(ctx.alloc, ci);
    }
    std.mem.sort(usize, insts.items, ctx, struct {
        fn less(c: *context.Context, a: usize, b: usize) bool {
            return std.mem.order(u8, c.mod.cells[a].name, c.mod.cells[b].name) == .lt;
        }
    }.less);
    for (insts.items) |ci| {
        const c = ctx.mod.cells[ci];
        const xpm = sync.primitives.isXpmPrimitive(c.type);
        const hint: []const u8 = if (xpm) " (XPM accepts 2..10)" else "";
        for (sync.primitives.depthParams(c.type, ctx.cfg.sync_primitives)) |param| {
            const depth = sync.primitives.syncDepth(c, param, xpm) orelse continue;
            if (depth >= ctx.cfg.sync_depth) continue;
            const message = try std.fmt.allocPrint(ctx.alloc,
                "synchroniser primitive `{s}` (`{s}`) declares {s}={d}, below the project's required synchroniser depth of {d}. The macro's stage count is a parameter, not a flop chain, so CDC-002 cannot see it. Raise {s} on the instantiation{s} or lower --sync-depth if {d} stages are sufficient here.",
                .{ c.name, sync.primitives.normaliseType(c.type), param, depth, ctx.cfg.sync_depth, param, hint, depth });
            try out.append(ctx.alloc, .{
                .rule = rule.id,
                .severity = rule.severity,
                .dst = c.name,
                .message = message,
            });
        }
    }
    return out.toOwnedSlice(ctx.alloc);
}

