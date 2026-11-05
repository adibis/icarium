const std = @import("std");
const clock = @import("icarium").clock;
const ir = @import("icarium").ir;
const sdc = @import("icarium").sdc;

const Loaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    asg: clock.trace.Assignment,
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
    const asg = try clock.trace.assign(std.testing.allocator, &mod, &sdc_mod);
    return .{ .mod = mod, .sdc_mod = sdc_mod, .asg = asg };
}

fn domFor(l: *const Loaded, cell_name: []const u8) ?clock.trace.Domain {
    for (l.asg.flops) |f| {
        if (std.mem.eql(u8, l.mod.cells[f.cell].name, cell_name)) return f.domain;
    }
    return null;
}

fn freeAll(l: *Loaded) void {
    l.asg.deinit();
    l.sdc_mod.deinit();
    l.mod.deinit();
}

const direct_inv =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [4]},
    \\        "q2": {"direction": "output", "bits": [5]}
    \\      },
    \\      "cells": {
    \\        "f_direct": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [4]}
    \\        },
    \\        "inv": {
    \\          "type": "$not",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [2], "Y": [6]}
    \\        },
    \\        "f_inv": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [6], "D": [3], "Q": [5]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "direct and inverted clocks resolve" {
    var l = try loadAll(direct_inv, "create_clock -name clk -period 10 [get_ports clk]\n");
    defer freeAll(&l);
    const direct = domFor(&l, "f_direct").?;
    try std.testing.expectEqualStrings("clk", direct.name);
    try std.testing.expectEqualStrings("clk", direct.root);
    try std.testing.expectEqual(@as(usize, 0), direct.notes.len);
    const inv = domFor(&l, "f_inv").?;
    try std.testing.expectEqualStrings("clk", inv.name);
    try std.testing.expectEqual(@as(usize, 1), inv.notes.len);
    try std.testing.expectEqualStrings("inverted clock", inv.notes[0]);
}

test "undeclared roots get synthetic domains" {
    var l = try loadAll(direct_inv, null);
    defer freeAll(&l);
    const direct = domFor(&l, "f_direct").?;
    try std.testing.expectEqualStrings("port:clk", direct.name);
    try std.testing.expectEqualStrings("clk", direct.root);
    try std.testing.expectEqualStrings("undeclared clock root", direct.notes[0]);
}

const exotic =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [4]}
    \\      },
    \\      "cells": {
    \\        "pll": {
    \\          "type": "my_pll",
    \\          "port_directions": {"REF": "input", "OUT": "output"},
    \\          "connections": {"REF": [2], "OUT": [7]}
    \\        },
    \\        "f_bb": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [7], "D": [3], "Q": [4]}
    \\        },
    \\        "f_hang": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [9], "D": [3], "Q": [4]}
    \\        },
    \\        "f_src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [11]}
    \\        },
    \\        "f_div": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [11], "D": [3], "Q": [4]}
    \\        },
    \\        "mux": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [2], "S": ["0"], "Y": [12]}
    \\        },
    \\        "f_mux": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [12], "D": [3], "Q": [4]}
    \\        },
    \\        "f_noclk": {
    \\          "type": "$dff",
    \\          "port_directions": {"D": "input", "Q": "output"},
    \\          "connections": {"D": [3], "Q": [4]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "blackbox, hanging, divider, mux, and pinless clocks stay explicit" {
    var l = try loadAll(exotic, "create_clock -name clk -period 10 [get_ports clk]\n");
    defer freeAll(&l);
    try std.testing.expectEqualStrings("unknown", domFor(&l, "f_bb").?.name);
    try std.testing.expectEqualStrings("blackbox-driven clock", domFor(&l, "f_bb").?.notes[0]);
    try std.testing.expectEqualStrings("unknown", domFor(&l, "f_hang").?.name);
    try std.testing.expectEqualStrings("undriven clock", domFor(&l, "f_hang").?.notes[0]);
    try std.testing.expectEqualStrings("unknown", domFor(&l, "f_div").?.name);
    try std.testing.expectEqualStrings("sequential clock driver", domFor(&l, "f_div").?.notes[0]);
    try std.testing.expectEqualStrings("unknown", domFor(&l, "f_mux").?.name);
    try std.testing.expectEqualStrings("unhandled $mux on clock path", domFor(&l, "f_mux").?.notes[0]);
    try std.testing.expectEqualStrings("unknown", domFor(&l, "f_noclk").?.name);
    try std.testing.expectEqualStrings("no CLK pin", domFor(&l, "f_noclk").?.notes[0]);
    try std.testing.expectEqualStrings("clk", domFor(&l, "f_src").?.name);
}

const disagree =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "other": {"direction": "input", "bits": [20]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [4]}
    \\      },
    \\      "cells": {
    \\        "f_wide": {
    \\          "type": "$dffe",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output", "EN": "input"},
    \\          "connections": {"CLK": [2, 20], "D": [3], "Q": [4], "EN": ["1"]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "disagreeing clock bits refuse to pick" {
    var l = try loadAll(disagree,
        \\create_clock -name clk -period 10 [get_ports clk]
        \\create_clock -name other -period 7 [get_ports other]
    );
    defer freeAll(&l);
    const dom = domFor(&l, "f_wide").?;
    try std.testing.expectEqualStrings("unknown", dom.name);
    try std.testing.expectEqualStrings("clock bits disagree", dom.notes[0]);
}

const renamed =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "bare": {"direction": "input", "bits": [21]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [4]},
    \\        "q2": {"direction": "output", "bits": [5]}
    \\      },
    \\      "cells": {
    \\        "f_sys": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [4]}
    \\        },
    \\        "f_bare": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [21], "D": [3], "Q": [5]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "roots resolve by objects first, name second" {
    var l = try loadAll(renamed,
        \\create_clock -name sys -period 10 [get_ports clk]
        \\create_clock -name bare -period 5
    );
    defer freeAll(&l);
    const sys = domFor(&l, "f_sys").?;
    try std.testing.expectEqualStrings("sys", sys.name);
    try std.testing.expectEqualStrings("clk", sys.root);
    try std.testing.expectEqualStrings("bare", domFor(&l, "f_bare").?.name);
}

test "cell tables recognize sequential and transparent" {
    try std.testing.expect(clock.cells.isSequential("$dff"));
    try std.testing.expect(clock.cells.isSequential("$adff"));
    try std.testing.expect(clock.cells.isSequential("$dlatch"));
    try std.testing.expect(!clock.cells.isSequential("$mux"));
    try std.testing.expect(!clock.cells.isSequential("$memrd"));
    try std.testing.expect(clock.cells.isTransparent("$not"));
    try std.testing.expect(!clock.cells.isTransparent("$mux"));
}
