// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const ir = @import("icarium").ir;

fn loadFixture() !ir.types.Module {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/fixtures/yosys-names.json",
        std.testing.allocator,
        .limited(1 << 20),
    );
    defer std.testing.allocator.free(bytes);
    return ir.load.loadFromSlice(std.testing.allocator, bytes, "names");
}

// Cells by the source line of the statement that made them, so the
// test does not depend on Yosys's pass numbering.
fn cellAt(mod: *const ir.types.Module, line: []const u8) usize {
    for (mod.cells, 0..) |c, i| {
        const s = c.src orelse continue;
        const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse continue;
        if (std.mem.startsWith(u8, s[colon + 1 ..], line) and s[colon + 1 + line.len] == '.') return i;
    }
    unreachable;
}

fn allCells(alloc: std.mem.Allocator, mod: *const ir.types.Module) ![]usize {
    const out = try alloc.alloc(usize, mod.cells.len);
    for (out, 0..) |*o, i| o.* = i;
    return out;
}

const expected = [_]struct { line: []const u8, name: []const u8 }{
    .{ .line = "7", .name = "u_a.q_reg" }, // submodule register, not the parent wire
    .{ .line = "12", .name = "u_mid.u_leaf.q" }, // two levels down
    .{ .line = "34", .name = "up" }, // ascending range, whole register
    .{ .line = "35", .name = "dout" },
    .{ .line = "36", .name = "o" }, // shares its D net with bus[3]
    .{ .line = "37", .name = "bus[3]" },
    .{ .line = "38", .name = "bus[5:4]" },
    .{ .line = "39", .name = "p" }, // a gate names its output net
};

test "flops take the register the RTL wrote" {
    var mod = try loadFixture();
    defer mod.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = try ir.names.build(a, &mod, try allCells(a, &mod));
    for (expected) |e| {
        const got = names.get(cellAt(&mod, e.line)) orelse {
            std.debug.print("line {s}: no name\n", .{e.line});
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(e.name, got);
    }
}

test "without proc's next-state nets, the output net in the cell's own scope wins" {
    var mod = try loadFixture();
    defer mod.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var drop: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = mod.netnames.keyIterator();
    while (it.next()) |k| if (std.mem.indexOf(u8, k.*, "$0\\") != null) try drop.append(a, k.*);
    for (drop.items) |k| _ = mod.netnames.remove(k);
    const names = try ir.names.build(a, &mod, try allCells(a, &mod));
    // u_a.q and u_a.q_reg are both in scope; the shorter one wins.
    try std.testing.expectEqualStrings("u_a.q", names.get(cellAt(&mod, "7")).?);
    try std.testing.expectEqualStrings("u_mid.u_leaf.q", names.get(cellAt(&mod, "12")).?);
    try std.testing.expectEqualStrings("bus[3]", names.get(cellAt(&mod, "37")).?);
}

test "only the cells asked for are named" {
    var mod = try loadFixture();
    defer mod.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const one = [_]usize{cellAt(&mod, "36")};
    const names = try ir.names.build(arena.allocator(), &mod, &one);
    try std.testing.expectEqual(@as(u32, 1), names.count());
    try std.testing.expectEqualStrings("o", names.get(one[0]).?);
}
