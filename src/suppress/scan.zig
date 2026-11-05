const std = @import("std");
const clock = @import("../clock.zig");
const ir = @import("../ir.zig");
const reset = @import("../reset.zig");
const rule = @import("../rule.zig");

// Scan-mode opt-out: flops whose clock or reset fans in from a
// `(* scan_en *)` net behave differently under shift, so their
// findings excuse when the user passes --ignore-scan-mode. The
// walk stops at flop boundaries: scan data shifting through Q
// is ordinary data path, not scan control.
pub fn apply(
    alloc: std.mem.Allocator,
    mod: *const ir.types.Module,
    findings: []rule.finding.Finding,
) error{OutOfMemory}!void {
    const tagged = try tagCells(alloc, mod);
    for (findings) |*f| {
        if (f.waiver != null) continue;
        if (!tagged.contains(f.dst)) continue;
        f.waiver = .{
            .id = "scan",
            .reason = "scan-tagged clock/reset path (--ignore-scan-mode)",
            .location = null,
        };
    }
}

pub fn tagCells(alloc: std.mem.Allocator, mod: *const ir.types.Module) error{OutOfMemory}!std.StringHashMapUnmanaged(void) {
    var tagged = std.StringHashMapUnmanaged(void).empty;
    var seen = std.AutoHashMapUnmanaged(u32, void).empty;
    var frontier = std.ArrayListUnmanaged(u32).empty;
    var nnit = mod.netnames.iterator();
    while (nnit.next()) |nn| {
        var hit = false;
        for (nn.value_ptr.attrs) |a| {
            if (std.mem.eql(u8, a.name, "scan_en")) {
                hit = true;
                break;
            }
        }
        if (!hit) continue;
        for (nn.value_ptr.bits) |b| {
            if (b == .sig) try frontier.append(alloc, b.sig);
        }
    }
    var head: usize = 0;
    while (head < frontier.items.len) : (head += 1) {
        const bit = frontier.items[head];
        if (seen.contains(bit)) continue;
        try seen.put(alloc, bit, {});
        const loads = mod.loads_of.get(bit) orelse continue;
        for (loads.items) |load| {
            const ci = load.cell orelse continue;
            const c = mod.cells[ci];
            if (clock.cells.isSequential(c.type) or clock.cells.isLatch(c.type)) {
                if (isClockOrResetPin(c, load.port)) try tagged.put(alloc, c.name, {});
                continue;
            }
            if (c.blackbox) continue;
            for (c.ports) |p| {
                if (p.direction != .output) continue;
                for (p.bits) |b| {
                    if (b == .sig) try frontier.append(alloc, b.sig);
                }
            }
        }
    }
    return tagged;
}

// Clock pins plus the cell's own reset vocabulary: the reset
// table owns pin names, so new cell types arrive for free.
fn isClockOrResetPin(c: ir.types.Cell, port: []const u8) bool {
    if (std.mem.eql(u8, port, "CLK") or std.mem.eql(u8, port, "G")) return true;
    const rp = reset.cells.resetPins(c.type) orelse return false;
    for (rp.async) |ap| {
        if (std.mem.eql(u8, ap.pin, port)) return true;
    }
    for (rp.sync) |sp| {
        if (std.mem.eql(u8, sp, port)) return true;
    }
    return false;
}
