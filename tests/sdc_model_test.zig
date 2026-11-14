const std = @import("std");
const sdc = @import("icarium").sdc;

fn buildModel(arena: *std.heap.ArenaAllocator, text: []const u8) !sdc.model.Model {
    var warns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    const cmds = try sdc.tokens.parseCommands(arena.allocator(), text, &warns);
    var parsed: std.ArrayListUnmanaged(sdc.commands.Parsed) = .empty;
    for (cmds) |c| try parsed.append(arena.allocator(), try sdc.commands.parse(arena.allocator(), c, &warns));
    return sdc.model.build(std.testing.allocator, parsed.items);
}

test "async matrix follows declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try buildModel(&arena,
        \\create_clock -name a -period 10
        \\create_clock -name b -period 10
        \\create_clock -name c -period 5
        \\set_clock_groups -asynchronous -group {a} -group {b c}
    );
    defer mod.deinit();
    try std.testing.expect(!mod.areAsync("a", "a"));
    try std.testing.expect(mod.areAsync("a", "b"));
    try std.testing.expect(mod.areAsync("a", "c"));
    try std.testing.expect(!mod.areAsync("b", "c"));
}

test "generated lineage resolves to root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try buildModel(&arena,
        \\create_clock -name sys -period 10
        \\create_generated_clock -name div2 -source sys -divide_by 2
        \\create_generated_clock -name div4 -source div2 -divide_by 2
        \\create_clock -name usb -period 20
    );
    defer mod.deinit();
    try std.testing.expect(!mod.areAsync("sys", "div2"));
    try std.testing.expect(!mod.areAsync("div2", "div4"));
    try std.testing.expect(mod.areAsync("sys", "usb"));
    try std.testing.expect(mod.areAsync("div4", "usb"));
}

test "undeclared relations default async" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try buildModel(&arena, "create_clock -name a -period 1\ncreate_clock -name b -period 1\n");
    defer mod.deinit();
    try std.testing.expect(mod.areAsync("a", "b"));
    try std.testing.expect(mod.areAsync("a", "ghost"));
}

test "port typing resolves exact and glob" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try buildModel(&arena,
        \\create_clock -name clk -period 10
        \\create_clock -name io -period 40
        \\set_input_delay -clock clk [get_ports data]
        \\set_input_delay -clock io [get_ports io_*]
        \\set_output_delay -clock io [get_ports od]
    );
    defer mod.deinit();
    try std.testing.expectEqualStrings("clk", sdc.model.portClock(&mod, "data").?);
    try std.testing.expectEqualStrings("io", sdc.model.portClock(&mod, "io_sda").?);
    try std.testing.expectEqualStrings("io", sdc.model.portClock(&mod, "od").?);
    try std.testing.expect(sdc.model.portClock(&mod, "other") == null);
}

test "whole-bus glob types the bus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try buildModel(&arena,
        \\create_clock -name clk -period 10
        \\set_input_delay -clock clk [get_ports bus[*]]
    );
    defer mod.deinit();
    try std.testing.expectEqualStrings("clk", sdc.model.portClock(&mod, "bus").?);
}

test "clock roots resolve exact and glob" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try buildModel(&arena,
        \\create_clock -name sys -period 10 [get_ports clk]
        \\create_clock -name io -period 40 [get_ports io_*]
    );
    defer mod.deinit();
    try std.testing.expectEqualStrings("sys", sdc.model.rootClock(&mod, "clk").?);
    try std.testing.expectEqualStrings("io", sdc.model.rootClock(&mod, "io_sda").?);
    try std.testing.expect(sdc.model.rootClock(&mod, "other") == null);
}

test "contradictions and typos warn loudly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try buildModel(&arena,
        \\create_clock -name a -period 1
        \\create_clock -name a -period 2
        \\set_input_delay -clock a [get_ports d]
        \\set_input_delay -clock b [get_ports d]
        \\set_clock_groups -asynchronous -group {a} -group {typo}
    );
    defer mod.deinit();
    try std.testing.expect(mod.warnings.len >= 3);
    var saw_typo = false;
    for (mod.warnings) |w| {
        if (std.mem.indexOf(u8, w.text, "typo") != null) saw_typo = true;
    }
    try std.testing.expect(saw_typo);
}

test "exclusive groups warn and read async" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try buildModel(&arena,
        \\create_clock -name a -period 1
        \\create_clock -name b -period 1
        \\set_clock_groups -logically_exclusive -group {a} -group {b}
    );
    defer mod.deinit();
    try std.testing.expect(mod.areAsync("a", "b"));
    try std.testing.expect(mod.warnings.len >= 1);
}

test "master cycles warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mod = try buildModel(&arena,
        \\create_clock -name a -period 1
        \\create_generated_clock -name b -source c
        \\create_generated_clock -name c -source b
    );
    defer mod.deinit();
    var saw_cycle = false;
    for (mod.warnings) |w| {
        if (std.mem.indexOf(u8, w.text, "cycle") != null) saw_cycle = true;
    }
    try std.testing.expect(saw_cycle);
    try std.testing.expect(mod.areAsync("b", "c"));
}
