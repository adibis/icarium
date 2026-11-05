const std = @import("std");
const clock = @import("icarium").clock;
const ir = @import("icarium").ir;
const reset = @import("icarium").reset;
const sdc = @import("icarium").sdc;
const sync = @import("icarium").sync;

const Loaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    clock_asg: clock.trace.Assignment,
    table: sync.table.Table,
    marks: sync.attrs.Marks,
    reset_view: reset.trace.View,
    reset_syncs: reset.chains.Syncs,
};

fn loadAll(json: []const u8, sdc_text: ?[]const u8) !Loaded {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, json, null);
    errdefer mod.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var warns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    var sdc_mod: sdc.model.Model = undefined;
    if (sdc_text) |t| {
        const cmds = try sdc.tokens.parseCommands(arena.allocator(), t, &warns);
        var parsed: std.ArrayListUnmanaged(sdc.commands.Parsed) = .empty;
        for (cmds) |c| try parsed.append(arena.allocator(), try sdc.commands.parse(arena.allocator(), c, &warns));
        sdc_mod = try sdc.model.build(std.testing.allocator, parsed.items);
    } else {
        sdc_mod = try sdc.model.build(std.testing.allocator, &[_]sdc.commands.Parsed{});
    }
    errdefer sdc_mod.deinit();
    var clock_asg = try clock.trace.assign(std.testing.allocator, &mod, &sdc_mod);
    errdefer clock_asg.deinit();
    var table = try sync.table.build(std.testing.allocator, &mod, &clock_asg);
    errdefer table.deinit();
    var marks = try sync.attrs.collect(std.testing.allocator, &mod);
    errdefer marks.deinit();
    var reset_view = try reset.trace.assign(std.testing.allocator, &mod, &clock_asg);
    errdefer reset_view.deinit();
    var reset_syncs = try reset.chains.find(std.testing.allocator, &mod, &reset_view, &table.domains, &marks.reset_syncs);
    errdefer reset_syncs.deinit();
    return .{
        .mod = mod,
        .sdc_mod = sdc_mod,
        .clock_asg = clock_asg,
        .table = table,
        .marks = marks,
        .reset_view = reset_view,
        .reset_syncs = reset_syncs,
    };
}

fn freeAll(l: *Loaded) void {
    l.reset_syncs.deinit();
    l.reset_view.deinit();
    l.marks.deinit();
    l.table.deinit();
    l.clock_asg.deinit();
    l.sdc_mod.deinit();
    l.mod.deinit();
}

const one_sdc = "create_clock -name clk -period 10 [get_ports clk]\n";

const sync_chain =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "rst_n": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "s0": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": ["1"], "ARST": [3], "Q": [10]}
    \\        },
    \\        "s1": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [10], "ARST": [3], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a constant-fed same-reset chain is recognised" {
    var l = try loadAll(sync_chain, one_sdc);
    defer freeAll(&l);
    try std.testing.expectEqual(@as(usize, 1), l.reset_syncs.chains.len);
    const ch = l.reset_syncs.chains[0];
    try std.testing.expectEqual(@as(usize, 2), ch.flops.len);
    try std.testing.expect(l.reset_syncs.isMember("s0"));
    try std.testing.expect(l.reset_syncs.isMember("s1"));
    try std.testing.expect(ch.polarity == .low);
}

const port_fed =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "rst_n": {"direction": "input", "bits": [3]},
    \\        "go": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "s0": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "ARST": [3], "Q": [10]}
    \\        },
    \\        "s1": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [10], "ARST": [3], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a port-fed head is not a reset sync" {
    var l = try loadAll(port_fed, one_sdc);
    defer freeAll(&l);
    try std.testing.expectEqual(@as(usize, 0), l.reset_syncs.chains.len);
    try std.testing.expect(!l.reset_syncs.isMember("s0"));
}

const marked_chain =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "rst_n": {"direction": "input", "bits": [3]},
    \\        "go": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "netnames": {
    \\        "s0q": {"bits": [10], "attributes": {"reset_sync": 1}},
    \\        "s1q": {"bits": [12], "attributes": {"reset_sync": 1}}
    \\      },
    \\      "cells": {
    \\        "s0": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "ARST": [3], "Q": [10]}
    \\        },
    \\        "s1": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [10], "ARST": [3], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "marked stages join members but never chains" {
    var l = try loadAll(marked_chain, one_sdc);
    defer freeAll(&l);
    try std.testing.expectEqual(@as(usize, 0), l.reset_syncs.chains.len);
    try std.testing.expect(l.reset_syncs.isMember("s0"));
    try std.testing.expect(l.reset_syncs.isMember("s1"));
}

const polarity_marked =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "rst_n": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [6]}
    \\      },
    \\      "netnames": {
    \\        "rst_n": {"bits": [3], "attributes": {"reset_polarity": "low"}}
    \\      },
    \\      "cells": {
    \\        "f": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [6], "ARST": [3], "Q": [6]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "port polarity declarations are collected" {
    var l = try loadAll(polarity_marked, one_sdc);
    defer freeAll(&l);
    try std.testing.expect(l.marks.resetPolarity("rst_n") == .low);
    try std.testing.expect(l.marks.resetPolarity("clk") == null);
}
