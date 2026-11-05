const std = @import("std");
const clock = @import("icarium").clock;
const ir = @import("icarium").ir;
const reset = @import("icarium").reset;
const sdc = @import("icarium").sdc;

const Loaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    clock_asg: clock.trace.Assignment,
    view: reset.trace.View,
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
    const view = try reset.trace.assign(std.testing.allocator, &mod, &clock_asg);
    return .{ .mod = mod, .sdc_mod = sdc_mod, .clock_asg = clock_asg, .view = view };
}

fn flopFor(l: *const Loaded, cell_name: []const u8) ?reset.trace.FlopReset {
    for (l.view.flops) |f| {
        if (std.mem.eql(u8, l.mod.cells[f.cell].name, cell_name)) return f;
    }
    return null;
}

fn asyncPin(f: reset.trace.FlopReset, pin: []const u8) ?reset.trace.AsyncReset {
    for (f.async) |a| {
        if (std.mem.eql(u8, a.pin, pin)) return a;
    }
    return null;
}

fn freeAll(l: *Loaded) void {
    l.view.deinit();
    l.clock_asg.deinit();
    l.sdc_mod.deinit();
    l.mod.deinit();
}

const arst =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "rst": {"direction": "input", "bits": [3]},
    \\        "rst2": {"direction": "input", "bits": [4]},
    \\        "d": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [6]},
    \\        "p1": {"direction": "input", "bits": [7]},
    \\        "sel": {"direction": "input", "bits": [8]}
    \\      },
    \\      "netnames": {
    \\        "rst": {"hide_name": 0, "bits": [3], "attributes": {"reset_polarity": "low"}},
    \\        "rst2": {"hide_name": 0, "bits": [4], "attributes": {"reset_polarity": "HIGH"}}
    \\      },
    \\      "cells": {
    \\        "f_param": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [7], "D": [5], "Q": [6]},
    \\          "parameters": {"ARST_POLARITY": "1"}
    \\        },
    \\        "f_attr": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [3], "D": [5], "Q": [6]},
    \\          "parameters": {"ARST_POLARITY": "1"}
    \\        },
    \\        "f_attr_only": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [4], "D": [5], "Q": [6]},
    \\          "parameters": {}
    \\        },
    \\        "inv": {
    \\          "type": "$not",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [3], "Y": [10]}
    \\        },
    \\        "f_flip": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [10], "D": [5], "Q": [6]},
    \\          "parameters": {}
    \\        },
    \\        "f_tied": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": ["1"], "D": [5], "Q": [6]},
    \\          "parameters": {"ARST_POLARITY": "0"}
    \\        },
    \\        "mux_static": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [3], "B": [4], "S": ["0"], "Y": [11]}
    \\        },
    \\        "f_muxstatic": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [11], "D": [5], "Q": [6]},
    \\          "parameters": {}
    \\        },
    \\        "mux_dyn": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [3], "B": [4], "S": [8], "Y": [12]}
    \\        },
    \\        "f_muxdyn": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [12], "D": [5], "Q": [6]},
    \\          "parameters": {}
    \\        },
    \\        "f_src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [5], "Q": [13]}
    \\        },
    \\        "f_flop": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [13], "D": [5], "Q": [6]},
    \\          "parameters": {"ARST_POLARITY": "00000000000000000000000000000001"}
    \\        },
    \\        "pll": {
    \\          "type": "my_pll",
    \\          "port_directions": {"REF": "input", "OUT": "output"},
    \\          "connections": {"REF": [2], "OUT": [14]}
    \\        },
    \\        "f_bb": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [14], "D": [5], "Q": [6]},
    \\          "parameters": {}
    \\        },
    \\        "f_hang": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [99], "D": [5], "Q": [6]},
    \\          "parameters": {}
    \\        },
    \\        "f_noparam": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [7], "D": [5], "Q": [6]},
    \\          "parameters": {}
    \\        },
    \\        "f_sr": {
    \\          "type": "$dffsr",
    \\          "port_directions": {"CLK": "input", "SET": "input", "CLR": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "SET": [3], "CLR": ["0"], "D": [5], "Q": [6]},
    \\          "parameters": {"SET_POLARITY": "1", "CLR_POLARITY": 1}
    \\        },
    \\        "gate": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [3], "B": [4], "Y": [15]}
    \\        },
    \\        "f_comb": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [15], "D": [5], "Q": [6]},
    \\          "parameters": {"ARST_POLARITY": "1"}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const arst_sdc = "create_clock -name clk -period 10 [get_ports clk]\n";

test "async origins classify port, flop, constant, mux, comb" {
    var l = try loadAll(arst, arst_sdc);
    defer freeAll(&l);
    const param = asyncPin(flopFor(&l, "f_param").?, "ARST").?;
    try std.testing.expectEqual(reset.trace.Origin.port, param.origin);
    try std.testing.expectEqualStrings("p1", param.ref);
    const flop = asyncPin(flopFor(&l, "f_flop").?, "ARST").?;
    try std.testing.expectEqual(reset.trace.Origin.flop, flop.origin);
    try std.testing.expectEqualStrings("f_src", flop.ref);
    const tied = asyncPin(flopFor(&l, "f_tied").?, "ARST").?;
    try std.testing.expectEqual(reset.trace.Origin.constant, tied.origin);
    try std.testing.expectEqualStrings("1", tied.ref);
    const dyn = asyncPin(flopFor(&l, "f_muxdyn").?, "ARST").?;
    try std.testing.expectEqual(reset.trace.Origin.mux, dyn.origin);
    try std.testing.expectEqualStrings("mux_dyn", dyn.ref);
    try std.testing.expectEqualStrings("reset mux select not followed", dyn.notes[0]);
    const comb = asyncPin(flopFor(&l, "f_comb").?, "ARST").?;
    try std.testing.expectEqual(reset.trace.Origin.comb, comb.origin);
    try std.testing.expectEqualStrings("gate", comb.ref);
}

test "static reset mux follows its leg" {
    var l = try loadAll(arst, arst_sdc);
    defer freeAll(&l);
    const a = asyncPin(flopFor(&l, "f_muxstatic").?, "ARST").?;
    try std.testing.expectEqual(reset.trace.Origin.port, a.origin);
    try std.testing.expectEqualStrings("rst", a.ref);
    try std.testing.expectEqualStrings("reset mux static select A", a.notes[0]);
}

test "polarity prefers attribute, then param, then unknown" {
    var l = try loadAll(arst, arst_sdc);
    defer freeAll(&l);
    try std.testing.expectEqual(reset.trace.Polarity.high, asyncPin(flopFor(&l, "f_param").?, "ARST").?.polarity);
    const attr = asyncPin(flopFor(&l, "f_attr").?, "ARST").?;
    try std.testing.expectEqual(reset.trace.Polarity.low, attr.polarity);
    try std.testing.expectEqualStrings("polarity attribute overrides param", attr.notes[0]);
    try std.testing.expectEqual(reset.trace.Polarity.high, asyncPin(flopFor(&l, "f_attr_only").?, "ARST").?.polarity);
    try std.testing.expectEqual(reset.trace.Polarity.high, asyncPin(flopFor(&l, "f_flip").?, "ARST").?.polarity);
    try std.testing.expectEqual(reset.trace.Polarity.low, asyncPin(flopFor(&l, "f_tied").?, "ARST").?.polarity);
    try std.testing.expectEqual(reset.trace.Polarity.unknown, asyncPin(flopFor(&l, "f_noparam").?, "ARST").?.polarity);
    try std.testing.expectEqualStrings("polarity unknown", asyncPin(flopFor(&l, "f_noparam").?, "ARST").?.notes[0]);
}

test "set and clear pins resolve independently" {
    var l = try loadAll(arst, arst_sdc);
    defer freeAll(&l);
    const f = flopFor(&l, "f_sr").?;
    try std.testing.expectEqual(@as(usize, 2), f.async.len);
    const set = asyncPin(f, "SET").?;
    try std.testing.expectEqual(reset.trace.Origin.port, set.origin);
    try std.testing.expectEqual(reset.trace.Polarity.low, set.polarity);
    const clr = asyncPin(f, "CLR").?;
    try std.testing.expectEqual(reset.trace.Origin.constant, clr.origin);
    try std.testing.expectEqual(reset.trace.Polarity.high, clr.polarity);
}

test "blackbox and hanging resets stay explicit" {
    var l = try loadAll(arst, arst_sdc);
    defer freeAll(&l);
    const bb = asyncPin(flopFor(&l, "f_bb").?, "ARST").?;
    try std.testing.expectEqual(reset.trace.Origin.unknown, bb.origin);
    try std.testing.expectEqualStrings("blackbox-driven reset", bb.notes[0]);
    const hang = asyncPin(flopFor(&l, "f_hang").?, "ARST").?;
    try std.testing.expectEqual(reset.trace.Origin.unknown, hang.origin);
    try std.testing.expectEqualStrings("undriven reset", hang.notes[0]);
}

test "clock domain joins onto every flop" {
    var l = try loadAll(arst, arst_sdc);
    defer freeAll(&l);
    try std.testing.expectEqualStrings("clk", flopFor(&l, "f_param").?.clock.name);
    try std.testing.expectEqualStrings("clk", flopFor(&l, "f_sr").?.clock.name);
}

const synced =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "sr": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [5]}
    \\      },
    \\      "cells": {
    \\        "f_pin": {
    \\          "type": "$sdff",
    \\          "port_directions": {"CLK": "input", "SRST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "SRST": [3], "D": [4], "Q": [5]}
    \\        },
    \\        "mux": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": ["0"], "B": [4], "S": [3], "Y": [10]}
    \\        },
    \\        "f_mux": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [10], "Q": [5]}
    \\        },
    \\        "dmux": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [4], "B": [4], "S": [3], "Y": [11]}
    \\        },
    \\        "f_data": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [11], "Q": [5]}
    \\        },
    \\        "pmux": {
    \\          "type": "$pmux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [4], "B": [4], "S": [3], "Y": [12]}
    \\        },
    \\        "f_pmux": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [12], "Q": [5]}
    \\        },
    \\        "f_plain": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [5]}
    \\        },
    \\        "sr_cell": {
    \\          "type": "$sr",
    \\          "port_directions": {"SET": "input", "CLR": "input", "Q": "output"},
    \\          "connections": {"SET": [3], "CLR": ["0"], "Q": [5]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "sync pin and sync mux spellings both recognized" {
    var l = try loadAll(synced, arst_sdc);
    defer freeAll(&l);
    const pin = flopFor(&l, "f_pin").?.sync;
    try std.testing.expectEqual(reset.trace.SyncKind.pin, pin.kind);
    try std.testing.expectEqualStrings("SRST", pin.ref);
    try std.testing.expectEqual(reset.trace.Origin.port, pin.origin);
    const mux = flopFor(&l, "f_mux").?.sync;
    try std.testing.expectEqual(reset.trace.SyncKind.mux, mux.kind);
    try std.testing.expectEqualStrings("mux", mux.ref);
    try std.testing.expectEqual(reset.trace.Origin.port, mux.origin);
}

test "data muxes stay silent, pmuxes stay explicit" {
    var l = try loadAll(synced, arst_sdc);
    defer freeAll(&l);
    const data = flopFor(&l, "f_data").?.sync;
    try std.testing.expectEqual(reset.trace.SyncKind.none, data.kind);
    try std.testing.expectEqual(@as(usize, 0), data.notes.len);
    try std.testing.expectEqual(@as(usize, 0), flopFor(&l, "f_plain").?.async.len);
    const pmux = flopFor(&l, "f_pmux").?.sync;
    try std.testing.expectEqual(reset.trace.SyncKind.none, pmux.kind);
    try std.testing.expectEqualStrings("unhandled $pmux on D", pmux.notes[0]);
}

test "clockless cells join an explicit unknown clock" {
    var l = try loadAll(synced, arst_sdc);
    defer freeAll(&l);
    const f = flopFor(&l, "sr_cell").?;
    try std.testing.expectEqualStrings("unknown", f.clock.name);
    try std.testing.expectEqual(reset.trace.Origin.port, asyncPin(f, "SET").?.origin);
}

test "reset cell tables recognize pins and muxes" {
    const adff = reset.cells.resetPins("$adff").?;
    try std.testing.expectEqualStrings("ARST", adff.async[0].pin);
    try std.testing.expectEqualStrings("ARST_POLARITY", adff.async[0].polarity_param);
    try std.testing.expectEqual(@as(usize, 0), adff.sync.len);
    try std.testing.expectEqualStrings("SRST", reset.cells.resetPins("$sdff").?.sync[0]);
    try std.testing.expect(reset.cells.resetPins("$dff") == null);
    try std.testing.expectEqual(true, reset.cells.muxFollowStatic("$mux").?);
    try std.testing.expectEqual(false, reset.cells.muxFollowStatic("$pmux").?);
    try std.testing.expect(reset.cells.muxFollowStatic("$and") == null);
}
