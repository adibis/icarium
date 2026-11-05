const std = @import("std");
const crossing = @import("../crossing.zig");
const ir = @import("../ir.zig");
const sdc = @import("../sdc.zig");
const sync = @import("../sync.zig");

// Rule views plus the sync table (its memo is the only
// mutation rules may cause) and an index of bus records.
pub const Config = struct {
    sync_depth: u32 = 2,
};

pub const Context = struct {
    mod: *const ir.types.Module,
    model: *const sdc.model.Model,
    report: *const crossing.enumerate.Report,
    table: *sync.table.Table,
    marks: *const sync.attrs.Marks,
    buses: []const crossing.enumerate.Crossing,
    cfg: Config,
    alloc: std.mem.Allocator,

    pub fn isBusMember(ctx: *const Context, x: crossing.enumerate.Crossing) bool {
        if (x.kind != .flop_flop_bit) return false;
        const sc = x.src.cell orelse return false;
        for (ctx.buses) |b| {
            const bsc = b.src.cell orelse continue;
            const bdc = b.dst.cell orelse continue;
            const xdc = x.dst.cell orelse continue;
            if (bsc == sc and std.mem.eql(u8, b.src.port, x.src.port) and
                bdc == xdc and std.mem.eql(u8, b.dst.port, x.dst.port))
            {
                return true;
            }
        }
        return false;
    }
};

pub fn collectBuses(
    alloc: std.mem.Allocator,
    report: *const crossing.enumerate.Report,
) error{OutOfMemory}![]crossing.enumerate.Crossing {
    var out = std.ArrayListUnmanaged(crossing.enumerate.Crossing).empty;
    for (report.crossings) |x| {
        if (x.kind == .flop_flop_bus) try out.append(alloc, x);
    }
    return out.toOwnedSlice(alloc);
}
