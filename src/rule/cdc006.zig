const std = @import("std");
const clock = @import("../clock.zig");
const context = @import("context.zig");
const finding = @import("finding.zig");
const ir = @import("../ir.zig");
const registry = @import("registry.zig");
const sdc = @import("../sdc.zig");

pub const rule = registry.Rule{
    .id = "CDC-006",
    .severity = .err,
    .title = "Glitchy combinational source on a control crossing",
    .doc =
    \\A synchronizer first stage traces back through logic alone to
    \\top-level ports, with no registering flop: the chain can sample
    \\a transient no stable input ever held. Register the source in
    \\its own domain before synchronizing it.
    ,
    .honors = &.{"cdc_sync"},
    .check_all = checkAll,
};

// Proven first stages whose D fanin holds no flop but typed
// foreign ports. Clock, untyped, and same-domain defer out.
pub fn checkAll(ctx: *context.Context) error{OutOfMemory}![]finding.Finding {
    const mod = ctx.mod;
    var out = std.ArrayListUnmanaged(finding.Finding).empty;
    // Walks die per flop: data cones span the design, and one
    // retained walk per flop buried the full-top once pass.
    var backing = ctx.table.workArena();
    defer backing.deinit();
    var scratch = std.heap.ArenaAllocator.init(backing.allocator());
    defer scratch.deinit();
    for (mod.cells, 0..) |c, ci| {
        if (!clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) continue;
        const d = portBits(c, "D") orelse continue;
        const dom = ctx.table.domainOf(ci) orelse continue;
        if (std.mem.eql(u8, dom.name, "unknown")) continue;
        if (ctx.marks.hasSync(c.name)) continue;
        const depth = try ctx.table.chainDepth(mod, ci, dom.name);
        if (depth.depth < 2) continue;
        _ = scratch.reset(.retain_capacity);
        const fanin = try backwardFanin(ctx, scratch.allocator(), d);
        if (fanin.flops.items.len > 0) continue;
        var flagged = std.ArrayListUnmanaged(FlaggedPort).empty;
        for (fanin.ports.items) |p| {
            if (sdc.model.rootClock(ctx.model, p) != null) continue;
            const port_clk = sdc.model.portClock(ctx.model, p);
            if (port_clk == null) continue;
            if (sameRoot(ctx.model, port_clk.?, dom)) continue;
            try flagged.append(ctx.tmp, .{ .name = p, .clk = port_clk.? });
        }
        if (flagged.items.len == 0) continue;
        std.mem.sort(FlaggedPort, flagged.items, {}, struct {
            fn less(_: void, a: FlaggedPort, b: FlaggedPort) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        var descs = std.ArrayListUnmanaged([]const u8).empty;
        for (flagged.items) |fp| {
            try descs.append(ctx.tmp, try std.fmt.allocPrint(ctx.tmp, "{s} (clock={s})", .{ fp.name, fp.clk }));
        }
        const joined = try std.mem.join(ctx.tmp, ", ", descs.items);
        const message = try std.fmt.allocPrint(ctx.tmp,
            "glitchy combinational source on synchronizer {s} (clk={s}): D pin is driven by combinational logic with no registering flop, reaching unregistered top-level port(s): {s}",
            .{ c.name, dom.name, joined });
        try out.append(ctx.tmp, .{
            .rule = rule.id,
            .severity = rule.severity,
            .dst = c.name,
            .message = message,
        });
    }
    return out.toOwnedSlice(ctx.tmp);
}

const FlaggedPort = struct { name: []const u8, clk: []const u8 };

// A port is same-domain only when typed into every leg: one
// foreign leg means the sampling edge may be foreign too.
fn sameRoot(model: *const sdc.model.Model, port_clk: []const u8, dom: clock.trace.Domain) bool {
    const rp = model.rootOf(port_clk);
    if (std.mem.startsWith(u8, dom.name, "port:")) {
        const want = sdc.model.rootClock(model, dom.name["port:".len..]) orelse return false;
        return std.mem.eql(u8, rp, model.rootOf(want));
    }
    if (dom.legs.len == 0) return false;
    for (dom.legs) |leg| {
        if (!std.mem.eql(u8, rp, model.rootOf(leg))) return false;
    }
    return true;
}

const Fanin = struct {
    flops: std.ArrayListUnmanaged(usize),
    ports: std.ArrayListUnmanaged([]const u8),
};

// Reverse BFS from D through combinational cells: every flop Q
// and top input port reached. Twelve hops bound the walk.
fn backwardFanin(ctx: *context.Context, alloc: std.mem.Allocator, start: []ir.bits.Bit) error{OutOfMemory}!Fanin {
    const mod = ctx.mod;
    var flops = std.ArrayListUnmanaged(usize).empty;
    var ports = std.ArrayListUnmanaged([]const u8).empty;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(FrontierBit).empty;
    for (start) |b| {
        if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = 0 });
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const fb = frontier.items[head];
        if (seen.contains(fb.bit)) continue;
        try seen.put(alloc, fb.bit, {});
        const drv = mod.driver_of.get(fb.bit) orelse {
            if (portOfBit(mod, fb.bit)) |p| {
                if (p.direction == .input) try ports.append(alloc, p.name);
            }
            continue;
        };
        const ci = drv.cell orelse {
            if (portOfBit(mod, fb.bit)) |p| {
                if (p.direction == .input) try ports.append(alloc, p.name);
            }
            continue;
        };
        if (std.mem.eql(u8, drv.port, "Q")) {
            try flops.append(alloc, ci);
            continue;
        }
        if (fb.depth >= 12) continue;
        for (mod.cells[ci].ports) |p| {
            if (p.direction == .output) continue;
            for (p.bits) |b| {
                if (b == .sig) try frontier.append(alloc, .{ .bit = b.sig, .depth = fb.depth + 1 });
            }
        }
    }
    return .{ .flops = flops, .ports = ports };
}

const FrontierBit = struct { bit: u32, depth: u8 };

fn portOfBit(mod: *const ir.types.Module, bit: u32) ?ir.types.ModulePort {
    for (mod.ports) |p| {
        for (p.bits) |b| {
            if (b == .sig and b.sig == bit) return p;
        }
    }
    return null;
}

fn portBits(c: ir.types.Cell, want: []const u8) ?[]ir.bits.Bit {
    for (c.ports) |p| {
        if (std.mem.eql(u8, p.name, want)) return p.bits;
    }
    return null;
}
