const std = @import("std");
const clock = @import("icarium").clock;
const ir = @import("icarium").ir;
const sdc = @import("icarium").sdc;

const Loaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    asg: clock.trace.Assignment,
    awarns: std.ArrayListUnmanaged(sdc.tokens.Warning),
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
    var awarns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    const asg = try clock.trace.assign(std.testing.allocator, &mod, &sdc_mod, &awarns);
    return .{ .mod = mod, .sdc_mod = sdc_mod, .asg = asg, .awarns = awarns };
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
    \\        },
    \\        "buf": {
    \\          "type": "$buf",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [2], "Y": [7]}
    \\        },
    \\        "f_buf": {
    \\          "type": "$aldff",
    \\          "port_directions": {"CLK": "input", "ALOAD": "input", "AD": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [7], "ALOAD": ["0"], "AD": ["0"], "D": [3], "Q": [4]}
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
    const buf = domFor(&l, "f_buf").?;
    try std.testing.expectEqualStrings("clk", buf.name);
    try std.testing.expectEqual(@as(usize, 0), buf.notes.len);
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

test "exotic drivers resolve where possible, stay explicit otherwise" {
    var l = try loadAll(exotic, "create_clock -name clk -period 10 [get_ports clk]\n");
    defer freeAll(&l);
    try std.testing.expectEqualStrings("unknown", domFor(&l, "f_bb").?.name);
    try std.testing.expectEqualStrings("blackbox-driven clock", domFor(&l, "f_bb").?.notes[0]);
    try std.testing.expectEqualStrings("unknown", domFor(&l, "f_hang").?.name);
    try std.testing.expectEqualStrings("undriven clock", domFor(&l, "f_hang").?.notes[0]);
    try std.testing.expectEqualStrings("clk", domFor(&l, "f_div").?.name);
    try std.testing.expectEqualStrings("unrecognized divider, master kept", domFor(&l, "f_div").?.notes[0]);
    try std.testing.expectEqualStrings("clk", domFor(&l, "f_mux").?.name);
    try std.testing.expectEqualStrings("clock mux static select A", domFor(&l, "f_mux").?.notes[0]);
    try std.testing.expectEqualStrings("unknown", domFor(&l, "f_noclk").?.name);
    try std.testing.expectEqualStrings("no clock pin", domFor(&l, "f_noclk").?.notes[0]);
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

const muxed =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "sel": {"direction": "input", "bits": [4]},
    \\        "d": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [6]}
    \\      },
    \\      "cells": {
    \\        "mux_dyn": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [3], "S": [4], "Y": [10]}
    \\        },
    \\        "f_dyn": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [10], "D": [5], "Q": [6]}
    \\        },
    \\        "mux_static": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [3], "S": ["0"], "Y": [11]}
    \\        },
    \\        "f_static": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [11], "D": [5], "Q": [6]}
    \\        },
    \\        "mux_same": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [2], "S": [4], "Y": [12]}
    \\        },
    \\        "f_same": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [12], "D": [5], "Q": [6]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const mux_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
;

test "dynamic mux yields a union with legs" {
    var l = try loadAll(muxed, mux_sdc);
    defer freeAll(&l);
    const dom = domFor(&l, "f_dyn").?;
    try std.testing.expectEqualStrings("ca+cb", dom.name);
    try std.testing.expectEqual(@as(usize, 2), dom.legs.len);
    try std.testing.expectEqualStrings("ca", dom.legs[0]);
    try std.testing.expectEqualStrings("cb", dom.legs[1]);
    try std.testing.expectEqualStrings("mux:mux_dyn", dom.root);
    try std.testing.expectEqualStrings("clock mux select: port sel", dom.notes[0]);
    try std.testing.expectEqual(@as(usize, 2), dom.sels.len);
    try std.testing.expectEqualStrings("mux_dyn", l.mod.cells[dom.sels[0].mux].name);
    try std.testing.expectEqual(@as(u8, 0), dom.sels[0].side);
    try std.testing.expectEqualStrings("mux_dyn", l.mod.cells[dom.sels[1].mux].name);
    try std.testing.expectEqual(@as(u8, 1), dom.sels[1].side);
    try std.testing.expectEqual(@as(usize, 1), dom.muxes.len);
    try std.testing.expectEqualStrings("mux_dyn", l.mod.cells[dom.muxes[0]].name);
    try std.testing.expect(dom.sels[0].gate == null);
    try std.testing.expectEqualStrings("port:sel", dom.sels[0].sel_dom);
    try std.testing.expectEqualStrings("port:sel", dom.sels[1].sel_dom);
}

test "static mux resolves its leg" {
    var l = try loadAll(muxed, mux_sdc);
    defer freeAll(&l);
    const dom = domFor(&l, "f_static").?;
    try std.testing.expectEqualStrings("ca", dom.name);
    try std.testing.expectEqualStrings("clock mux static select A", dom.notes[0]);
}

test "same-domain mux passes through with a note" {
    var l = try loadAll(muxed, mux_sdc);
    defer freeAll(&l);
    const dom = domFor(&l, "f_same").?;
    try std.testing.expectEqualStrings("ca", dom.name);
    try std.testing.expectEqualStrings("clock mux select: port sel", dom.notes[0]);
    try std.testing.expectEqual(@as(usize, 0), dom.sels.len);
    try std.testing.expectEqual(@as(usize, 0), dom.muxes.len);
}

const gated =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "en": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [5]}
    \\      },
    \\      "cells": {
    \\        "gate": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [3], "Y": [10]}
    \\        },
    \\        "f_gated": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [10], "D": [4], "Q": [5]}
    \\        },
    \\        "f_en": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [11]}
    \\        },
    \\        "gate2": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [11], "Y": [12]}
    \\        },
    \\        "f_gated2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [12], "D": [4], "Q": [5]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "gated clocks keep the clock leg and name the enable" {
    var l = try loadAll(gated, "create_clock -name clk -period 10 [get_ports clk]\n");
    defer freeAll(&l);
    const port_en = domFor(&l, "f_gated").?;
    try std.testing.expectEqualStrings("clk", port_en.name);
    try std.testing.expectEqualStrings("clock gate enable: port en", port_en.notes[0]);
    const flop_en = domFor(&l, "f_gated2").?;
    try std.testing.expectEqualStrings("clk", flop_en.name);
    try std.testing.expectEqualStrings("clock gate enable: cell f_en", flop_en.notes[0]);
}

const divided =
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
    \\        "div": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [7], "Q": [6]}
    \\        },
    \\        "inv": {
    \\          "type": "$not",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [6], "Y": [7]}
    \\        },
    \\        "f_div2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [6], "D": [3], "Q": [4]}
    \\        },
    \\        "lat": {
    \\          "type": "$dlatch",
    \\          "port_directions": {"D": "input", "G": "input", "Q": "output"},
    \\          "connections": {"D": [3], "G": [2], "Q": [5]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "toggle divider keeps master with a ratio note" {
    var l = try loadAll(divided, "create_clock -name clk -period 10 [get_ports clk]\n");
    defer freeAll(&l);
    const dom = domFor(&l, "f_div2").?;
    try std.testing.expectEqualStrings("clk", dom.name);
    try std.testing.expectEqualStrings("divide-by-2, master kept", dom.notes[0]);
}

test "latches trace their gate pin" {
    var l = try loadAll(divided, "create_clock -name clk -period 10 [get_ports clk]\n");
    defer freeAll(&l);
    try std.testing.expectEqualStrings("clk", domFor(&l, "lat").?.name);
}

fn controlFor(l: *const Loaded, cell_name: []const u8, pin: []const u8) ?clock.trace.ControlPin {
    for (l.asg.controls) |cp| {
        if (std.mem.eql(u8, l.mod.cells[cp.cell].name, cell_name) and std.mem.eql(u8, cp.pin, pin))
            return cp;
    }
    return null;
}

test "dynamic mux select is recorded, static is not" {
    var l = try loadAll(muxed, mux_sdc);
    defer freeAll(&l);
    const sel = controlFor(&l, "mux_dyn", "S").?;
    try std.testing.expectEqualStrings("port:sel", sel.domain.name);
    try std.testing.expect(controlFor(&l, "mux_static", "S") == null);
    try std.testing.expect(controlFor(&l, "mux_same", "S") != null);
}

test "gate enables are recorded with their domains" {
    var l = try loadAll(gated, "create_clock -name clk -period 10 [get_ports clk]\n");
    defer freeAll(&l);
    try std.testing.expectEqualStrings("port:en", controlFor(&l, "gate", "B").?.domain.name);
    try std.testing.expectEqualStrings("clk", controlFor(&l, "gate2", "B").?.domain.name);
    try std.testing.expect(controlFor(&l, "gate", "A") == null);
}

test "cell tables recognize sequential and transparent" {
    try std.testing.expect(clock.cells.isSequential("$dff"));
    try std.testing.expect(clock.cells.isSequential("$adff"));
    try std.testing.expect(clock.cells.isSequential("$dlatch"));
    try std.testing.expect(clock.cells.isSequential("$adffe"));
    try std.testing.expect(clock.cells.isSequential("$aldff"));
    try std.testing.expect(clock.cells.isSequential("$aldffe"));
    try std.testing.expect(clock.cells.isSequential("$dlatchsr"));
    try std.testing.expect(clock.cells.isSequential("$sr"));
    try std.testing.expect(!clock.cells.isSequential("$mux"));
    try std.testing.expect(!clock.cells.isSequential("$memrd"));
    try std.testing.expect(clock.cells.isTransparent("$not"));
    try std.testing.expect(clock.cells.isTransparent("$buf"));
    try std.testing.expect(clock.cells.isTransparent("$logic_not"));
    try std.testing.expect(!clock.cells.isTransparent("$mux"));
    try std.testing.expect(clock.cells.isInverting("$not"));
    try std.testing.expect(clock.cells.isInverting("$logic_not"));
    try std.testing.expect(!clock.cells.isInverting("$buf"));
    try std.testing.expect(clock.cells.isClockMux("$mux"));
    try std.testing.expect(!clock.cells.isClockMux("$pmux"));
    try std.testing.expect(clock.cells.isClockGate("$and"));
    try std.testing.expect(!clock.cells.isClockGate("$or"));
    try std.testing.expect(clock.cells.isMemoryClock("$memrd"));
    try std.testing.expect(clock.cells.isMemoryClock("$memwr_v2"));
    try std.testing.expect(!clock.cells.isMemoryClock("$mem"));
    try std.testing.expect(clock.cells.isMemRead("$memrd"));
    try std.testing.expect(!clock.cells.isMemRead("$memwr"));
}

const ormuxed =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "ena": {"direction": "input", "bits": [4]},
    \\        "enb": {"direction": "input", "bits": [5]},
    \\        "d": {"direction": "input", "bits": [6]},
    \\        "q": {"direction": "output", "bits": [7]},
    \\        "q2": {"direction": "output", "bits": [8]}
    \\      },
    \\      "cells": {
    \\        "and0": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [4], "Y": [10]}
    \\        },
    \\        "and1": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [3], "B": [5], "Y": [11]}
    \\        },
    \\        "ormux": {
    \\          "type": "$or",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [11], "Y": [12]}
    \\        },
    \\        "f_or": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [12], "D": [6], "Q": [7]}
    \\        },
    \\        "bador": {
    \\          "type": "$or",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [3], "Y": [13]}
    \\        },
    \\        "f_bador": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [13], "D": [6], "Q": [8]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "or of gated clocks yields a union with legs" {
    var l = try loadAll(ormuxed, mux_sdc);
    defer freeAll(&l);
    const dom = domFor(&l, "f_or").?;
    try std.testing.expectEqualStrings("ca+cb", dom.name);
    try std.testing.expectEqual(@as(usize, 2), dom.legs.len);
    try std.testing.expectEqualStrings("ca", dom.legs[0]);
    try std.testing.expectEqualStrings("cb", dom.legs[1]);
    try std.testing.expectEqualStrings("ormux:ormux", dom.root);
    try std.testing.expectEqualStrings("or-built clock mux", dom.notes[0]);
    try std.testing.expectEqual(@as(usize, 2), dom.sels.len);
    try std.testing.expectEqualStrings("ormux", l.mod.cells[dom.sels[0].mux].name);
    try std.testing.expectEqual(@as(u8, 0), dom.sels[0].side);
    try std.testing.expectEqualStrings("ormux", l.mod.cells[dom.sels[1].mux].name);
    try std.testing.expectEqual(@as(u8, 1), dom.sels[1].side);
    try std.testing.expectEqual(@as(usize, 1), dom.muxes.len);
    try std.testing.expectEqualStrings("ormux", l.mod.cells[dom.muxes[0]].name);
    const g0 = dom.sels[0].gate.?;
    try std.testing.expectEqualStrings("and0", l.mod.cells[g0.cell].name);
    try std.testing.expectEqualStrings("A", g0.pin);
    try std.testing.expectEqual(@as(u32, 2), g0.bit);
    const g1 = dom.sels[1].gate.?;
    try std.testing.expectEqualStrings("and1", l.mod.cells[g1.cell].name);
    try std.testing.expectEqual(@as(u32, 3), g1.bit);
    try std.testing.expectEqual(@as(usize, 0), dom.sels[0].sel_dom.len);
}

test "naked or of clocks unions without selects" {
    var l = try loadAll(ormuxed, mux_sdc);
    defer freeAll(&l);
    const dom = domFor(&l, "f_bador").?;
    try std.testing.expectEqualStrings("ca+cb", dom.name);
    try std.testing.expectEqual(@as(usize, 2), dom.legs.len);
    try std.testing.expectEqual(@as(usize, 0), dom.sels.len);
    try std.testing.expectEqualStrings("or-combined clocks", dom.notes[0]);
}

// Slang emits boolean clock spines as $logic_and/$logic_or
// widens instead of bitwise twins; unions must still form.
const logic_ormux =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "ena": {"direction": "input", "bits": [4]},
    \\        "enb": {"direction": "input", "bits": [5]},
    \\        "d": {"direction": "input", "bits": [6]},
    \\        "q": {"direction": "output", "bits": [7]}
    \\      },
    \\      "cells": {
    \\        "and0": {
    \\          "type": "$logic_and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [4], "Y": [10]}
    \\        },
    \\        "and1": {
    \\          "type": "$logic_and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [3], "B": [5], "Y": [11]}
    \\        },
    \\        "ormux": {
    \\          "type": "$logic_or",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [11], "Y": [12]}
    \\        },
    \\        "f_or": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [12], "D": [6], "Q": [7]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "boolean twin spine yields the same union" {
    var l = try loadAll(logic_ormux, mux_sdc);
    defer freeAll(&l);
    const dom = domFor(&l, "f_or").?;
    try std.testing.expectEqualStrings("ca+cb", dom.name);
    try std.testing.expectEqual(@as(usize, 2), dom.legs.len);
    try std.testing.expectEqual(@as(usize, 2), dom.sels.len);
}

const osc_net =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [4]}
    \\      },
    \\      "netnames": {
    \\        "osc_clk": {"hide_name": 0, "bits": [2]}
    \\      },
    \\      "cells": {
    \\        "gbuf": {
    \\          "type": "$buf",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [2], "Y": [5]}
    \\        },
    \\        "f_osc": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [5], "D": [3], "Q": [4]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "internal root on a netname types the cone" {
    var l = try loadAll(osc_net, "create_clock -name osc -period 10 [get_nets osc_clk]\n");
    defer freeAll(&l);
    const dom = domFor(&l, "f_osc").?;
    try std.testing.expectEqualStrings("osc", dom.name);
    try std.testing.expectEqualStrings("osc_clk", dom.root);
    try std.testing.expectEqual(@as(usize, 0), l.awarns.items.len);
}

test "internal root on a cell pin types the cone" {
    var l = try loadAll(osc_net, "create_clock -name g -period 10 [get_pins gbuf/Y]\n");
    defer freeAll(&l);
    const dom = domFor(&l, "f_osc").?;
    try std.testing.expectEqualStrings("g", dom.name);
    try std.testing.expectEqual(@as(usize, 0), l.awarns.items.len);
}

test "unmatched root warns and stays unknown" {
    var l = try loadAll(osc_net, "create_clock -name ghost -period 10 [get_nets nope]\n");
    defer freeAll(&l);
    const dom = domFor(&l, "f_osc").?;
    try std.testing.expectEqualStrings("unknown", dom.name);
    try std.testing.expectEqual(@as(usize, 1), l.awarns.items.len);
    try std.testing.expect(std.mem.indexOf(u8, l.awarns.items[0].text, "unmatched: nope") != null);
}

test "overlapping roots warn, first sorted pattern wins" {
    var l = try loadAll(osc_net, "create_clock -name A -period 10 [get_nets osc*]\ncreate_clock -name B -period 10 [get_nets *clk]\n");
    defer freeAll(&l);
    const dom = domFor(&l, "f_osc").?;
    try std.testing.expectEqualStrings("B", dom.name);
    try std.testing.expectEqual(@as(usize, 1), l.awarns.items.len);
    try std.testing.expect(std.mem.indexOf(u8, l.awarns.items[0].text, "overlaps 1 rooted bit") != null);
}

// Latch-gated oscillator: the latch reports its master's
// domain, but the gate must still validate on the one clock
// leg and name the latch an enable, not a second clock.
const gated_osc =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "osc": {"direction": "input", "bits": [2]},
    \\        "en_dat": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [5]}
    \\      },
    \\      "cells": {
    \\        "lo": {
    \\          "type": "$dlatch",
    \\          "port_directions": {"D": "input", "EN": "input", "Q": "output"},
    \\          "connections": {"D": [3], "EN": [2], "Q": [10]}
    \\        },
    \\        "g0": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [2], "Y": [11]}
    \\        },
    \\        "f": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [11], "D": [4], "Q": [5]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const gated_osc_sdc =
    \\create_clock -name sys_osc -period 10 [get_ports osc]
;

test "latch-gated clock validates and names the latch" {
    var l = try loadAll(gated_osc, gated_osc_sdc);
    defer freeAll(&l);
    const dom = domFor(&l, "f").?;
    try std.testing.expectEqualStrings("sys_osc", dom.name);
    try std.testing.expectEqualStrings("clock gate enable: cell lo", dom.notes[0]);
}

// Bypass-OR replica: gated osc OR muxed(ext, osc). The mux
// leg arrives already unioned; the OR flattens it rather
// than rejecting a leg it cannot select-analyze.
const bypass_or =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "osc": {"direction": "input", "bits": [2]},
    \\        "extp": {"direction": "input", "bits": [6]},
    \\        "en_dat": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [5]}
    \\      },
    \\      "cells": {
    \\        "lo": {
    \\          "type": "$dlatch",
    \\          "port_directions": {"D": "input", "EN": "input", "Q": "output"},
    \\          "connections": {"D": [3], "EN": [2], "Q": [10]}
    \\        },
    \\        "g0": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [2], "Y": [11]}
    \\        },
    \\        "mux0": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [6], "B": [2], "S": [4], "Y": [12]}
    \\        },
    \\        "or0": {
    \\          "type": "$or",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [11], "B": [12], "Y": [13]}
    \\        },
    \\        "f": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [13], "D": [4], "Q": [5]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const bypass_or_sdc =
    \\create_clock -name sys_osc -period 10 [get_ports osc]
    \\create_clock -name ext -period 10 [get_ports extp]
;

test "or of gated and muxed clocks flattens the union" {
    var l = try loadAll(bypass_or, bypass_or_sdc);
    defer freeAll(&l);
    const dom = domFor(&l, "f").?;
    try std.testing.expectEqualStrings("ext+sys_osc", dom.name);
    try std.testing.expectEqual(@as(usize, 2), dom.legs.len);
    try std.testing.expectEqual(@as(usize, 0), dom.sels.len);
    try std.testing.expectEqualStrings("or-combined clocks", dom.notes[0]);
}

// Wide buffer on a clock path: only the clock lane continues;
// the data lane resolves on its own, never joined nor fatal.
const wide_buf =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "osc": {"direction": "input", "bits": [2]},
    \\        "dat": {"direction": "input", "bits": [4]},
    \\        "d": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [6]},
    \\        "q2": {"direction": "output", "bits": [7]}
    \\      },
    \\      "cells": {
    \\        "wb": {
    \\          "type": "$buf",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [2, 4], "Y": [20, 21]}
    \\        },
    \\        "fw": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [20], "D": [5], "Q": [6]}
    \\        },
    \\        "fd": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [21], "D": [5], "Q": [7]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "wide buffer follows the resolved lane" {
    var l = try loadAll(wide_buf, gated_osc_sdc);
    defer freeAll(&l);
    const w = domFor(&l, "fw").?;
    try std.testing.expectEqualStrings("sys_osc", w.name);
    const dd = domFor(&l, "fd").?;
    try std.testing.expectEqualStrings("port:dat", dd.name);
}

// Divider flop ANDed with a second clock: the toggle output
// is a clock, not an enable, so the gate must decline with
// multiple legs rather than pass one side silently.
const toggle_combine =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [5]}
    \\      },
    \\      "cells": {
    \\        "div": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [8], "Q": [6]}
    \\        },
    \\        "inv": {
    \\          "type": "$not",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [6], "Y": [8]}
    \\        },
    \\        "g0": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [6], "B": [3], "Y": [7]}
    \\        },
    \\        "f": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [7], "D": [4], "Q": [5]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "toggle flop leg counts as a second clock" {
    var l = try loadAll(toggle_combine, mux_sdc);
    defer freeAll(&l);
    const dom = domFor(&l, "f").?;
    try std.testing.expectEqualStrings("unknown", dom.name);
    try std.testing.expectEqualStrings("clock gate with multiple clock legs", dom.notes[0]);
}
