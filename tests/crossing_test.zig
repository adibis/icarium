const std = @import("std");
const clock = @import("icarium").clock;
const crossing = @import("icarium").crossing;
const ir = @import("icarium").ir;
const sdc = @import("icarium").sdc;

const Loaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    clock_asg: clock.trace.Assignment,
    report: crossing.enumerate.Report,
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
    const report = try crossing.enumerate.enumerate(std.testing.allocator, &mod, &clock_asg, &sdc_mod);
    return .{ .mod = mod, .sdc_mod = sdc_mod, .clock_asg = clock_asg, .report = report };
}

fn freeAll(l: *Loaded) void {
    l.report.deinit();
    l.clock_asg.deinit();
    l.sdc_mod.deinit();
    l.mod.deinit();
}

fn xFor(l: *const Loaded, kind: crossing.enumerate.Kind, src_bit: u32, dst_bit: u32) ?crossing.enumerate.Crossing {
    for (l.report.crossings) |x| {
        if (x.kind == kind and x.src.bit == src_bit and x.dst.bit == dst_bit) return x;
    }
    return null;
}

test "IDs match an independent hash vector" {
    const got = crossing.id.compute("flop_flop_bit", "c:u_a.q:Q:6", "c:u_b.d:D:6", "clk_a", "clk_b");
    try std.testing.expectEqualStrings("b3637e402f047facb4b636dddbf8f370", &got);
}

const pairs =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk_a": {"direction": "input", "bits": [2]},
    \\        "clk_b": {"direction": "input", "bits": [3]},
    \\        "din": {"direction": "input", "bits": [4]},
    \\        "raw": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "fa": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "fb": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [11]}
    \\        },
    \\        "fc": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [11], "Q": [12]}
    \\        },
    \\        "fd": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [5], "Q": [13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const pairs_sdc =
    \\create_clock -name clk_a -period 10 [get_ports clk_a]
    \\create_clock -name clk_b -period 7 [get_ports clk_b]
    \\set_clock_groups -asynchronous -group {clk_a} -group {clk_b}
    \\set_input_delay -clock clk_a [get_ports din]
;

test "flop and port pairs enumerate with async verdicts" {
    var l = try loadAll(pairs, pairs_sdc);
    defer freeAll(&l);
    try std.testing.expectEqual(@as(usize, 8), l.report.crossings.len);
    const async_pair = xFor(&l, .flop_flop_bit, 10, 10).?;
    try std.testing.expectEqualStrings("clk_a", async_pair.src_clk);
    try std.testing.expectEqualStrings("clk_b", async_pair.dst_clk);
    try std.testing.expect(async_pair.async_per_sdc);
    const sync_pair = xFor(&l, .flop_flop_bit, 11, 11).?;
    try std.testing.expect(!sync_pair.async_per_sdc);
    const typed = xFor(&l, .port_flop, 4, 4).?;
    try std.testing.expectEqualStrings("clk_a", typed.src_clk);
    try std.testing.expect(!typed.async_per_sdc);
    const untyped = xFor(&l, .port_flop_untyped, 5, 5).?;
    try std.testing.expectEqualStrings("port:raw", untyped.src_clk);
    try std.testing.expect(untyped.async_per_sdc);
}

const bus =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk_a": {"direction": "input", "bits": [2]},
    \\        "clk_b": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [20, 21]}
    \\      },
    \\      "cells": {
    \\        "u_sub.src2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [30, 31], "Q": [10, 11]},
    \\          "attributes": {"src": "bus.sv:1"}
    \\        },
    \\        "g1": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [10], "Y": [12]}
    \\        },
    \\        "n1": {
    \\          "type": "$not",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [12], "Y": [13]}
    \\        },
    \\        "u_sub.dst2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [11, 13], "Q": [20, 21]},
    \\          "attributes": {"src": "bus.sv:9"}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const bus_sdc =
    \\create_clock -name clk_a -period 10 [get_ports clk_a]
    \\create_clock -name clk_b -period 7 [get_ports clk_b]
    \\set_clock_groups -asynchronous -group {clk_a} -group {clk_b}
;

test "bus pairs group with lane maps and hops" {
    var l = try loadAll(bus, bus_sdc);
    defer freeAll(&l);
    try std.testing.expectEqual(@as(usize, 5), l.report.crossings.len);
    const bus_x = xFor(&l, .flop_flop_bus, 10, 13).?;
    try std.testing.expectEqual(@as(usize, 2), bus_x.lanes.len);
    try std.testing.expectEqual(@as(usize, 0), bus_x.lanes[0].src_lane);
    try std.testing.expectEqual(@as(usize, 1), bus_x.lanes[0].dst_lane);
    try std.testing.expectEqual(@as(usize, 1), bus_x.lanes[1].src_lane);
    try std.testing.expectEqual(@as(usize, 0), bus_x.lanes[1].dst_lane);
    try std.testing.expectEqual(@as(usize, 2), bus_x.hops.len);
    try std.testing.expectEqualStrings("g1", l.mod.cells[bus_x.hops[0]].name);
    try std.testing.expectEqualStrings("n1", l.mod.cells[bus_x.hops[1]].name);
    try std.testing.expect(bus_x.async_per_sdc);
    const direct = xFor(&l, .flop_flop_bit, 11, 11).?;
    try std.testing.expectEqual(@as(usize, 0), direct.hops.len);
}

test "records carry paths and source locations" {
    var l = try loadAll(bus, bus_sdc);
    defer freeAll(&l);
    const x = xFor(&l, .flop_flop_bit, 10, 13).?;
    try std.testing.expectEqualStrings("bus.sv:1", x.src_loc);
    try std.testing.expectEqualStrings("bus.sv:9", x.dst_loc);
    try std.testing.expectEqual(@as(usize, 1), x.instance_path.len);
    try std.testing.expectEqualStrings("u_sub", x.instance_path[0]);
}

const sinks =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [4]},
    \\        "clkin": {"direction": "input", "bits": [5]}
    \\      },
    \\      "cells": {
    \\        "f1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        },
    \\        "f2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [10], "D": [3], "Q": [11]}
    \\        },
    \\        "f3": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [5], "D": [3], "Q": [12]}
    \\        },
    \\        "bb": {
    \\          "type": "my_bb",
    \\          "port_directions": {"IN": "input", "OUT": "output"},
    \\          "connections": {"IN": [3], "OUT": [13]}
    \\        },
    \\        "f4": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [13], "Q": [14]}
    \\        },
    \\        "f5": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": ["0"], "Q": [15]}
    \\        },
    \\        "f6": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [99], "Q": [16]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const sinks_sdc = "create_clock -name clk -period 10 [get_ports clk]\n";

test "clock sinks and blackbox sources enumerate" {
    var l = try loadAll(sinks, sinks_sdc);
    defer freeAll(&l);
    try std.testing.expectEqual(@as(usize, 10), l.report.crossings.len);
    const div = xFor(&l, .clock_sink, 10, 10).?;
    try std.testing.expectEqualStrings("clk", div.src_clk);
    try std.testing.expectEqualStrings("clk", div.dst_clk);
    try std.testing.expect(!div.async_per_sdc);
    const ext = xFor(&l, .clock_sink, 5, 5).?;
    try std.testing.expectEqualStrings("port:clkin", ext.src_clk);
    try std.testing.expect(ext.async_per_sdc);
    const root = xFor(&l, .clock_sink, 2, 2).?;
    try std.testing.expectEqualStrings("clk", root.src_clk);
    try std.testing.expect(!root.async_per_sdc);
    const bb = xFor(&l, .flop_flop_bit, 13, 13).?;
    try std.testing.expectEqualStrings("unknown", bb.src_clk);
    try std.testing.expect(bb.async_per_sdc);
}

test "every sink bit lands in a record or is tied or undriven" {
    var l = try loadAll(sinks, sinks_sdc);
    defer freeAll(&l);
    var tied: usize = 0;
    var undriven: usize = 0;
    for (l.mod.cells, 0..) |c, ci| {
        for (c.ports) |p| {
            if (crossing.enumerate.sinkClass(c.type, p.name) == null) continue;
            for (p.bits) |b| {
                if (b != .sig) {
                    tied += 1;
                    continue;
                }
                if (l.mod.driver_of.get(b.sig) == null) {
                    undriven += 1;
                    continue;
                }
                var found = false;
                for (l.report.crossings) |x| {
                    if (x.dst.cell == ci and std.mem.eql(u8, x.dst.port, p.name) and x.dst.bit == b.sig) {
                        found = true;
                        break;
                    }
                }
                try std.testing.expect(found);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), tied);
    try std.testing.expectEqual(@as(usize, 1), undriven);
}

test "IDs survive cell reordering" {
    var l1 = try loadAll(pairs, pairs_sdc);
    defer freeAll(&l1);
    const reordered =
        \\{
        \\  "modules": {
        \\    "top": {
        \\      "ports": {
        \\        "q": {"direction": "output", "bits": [12]},
        \\        "raw": {"direction": "input", "bits": [5]},
        \\        "din": {"direction": "input", "bits": [4]},
        \\        "clk_b": {"direction": "input", "bits": [3]},
        \\        "clk_a": {"direction": "input", "bits": [2]}
        \\      },
        \\      "cells": {
        \\        "fd": {
        \\          "type": "$dff",
        \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
        \\          "connections": {"CLK": [2], "D": [5], "Q": [13]}
        \\        },
        \\        "fc": {
        \\          "type": "$dff",
        \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
        \\          "connections": {"CLK": [3], "D": [11], "Q": [12]}
        \\        },
        \\        "fb": {
        \\          "type": "$dff",
        \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
        \\          "connections": {"CLK": [3], "D": [10], "Q": [11]}
        \\        },
        \\        "fa": {
        \\          "type": "$dff",
        \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
        \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var l2 = try loadAll(reordered, pairs_sdc);
    defer freeAll(&l2);
    try std.testing.expectEqual(l1.report.crossings.len, l2.report.crossings.len);
    for (l1.report.crossings, l2.report.crossings) |a, b| {
        try std.testing.expectEqualStrings(a.id, b.id);
    }
}

const muxed_src =
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
    \\        "mux": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [3], "S": [4], "Y": [10]}
    \\        },
    \\        "fm": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [10], "D": [5], "Q": [11]}
    \\        },
    \\        "fd": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [11], "Q": [6]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const muxed_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
;

test "union sources go async on any async leg" {
    var l = try loadAll(muxed_src, muxed_sdc);
    defer freeAll(&l);
    const x = xFor(&l, .flop_flop_bit, 11, 11).?;
    try std.testing.expectEqualStrings("ca+cb", x.src_clk);
    try std.testing.expectEqualStrings("ca", x.dst_clk);
    try std.testing.expect(x.async_per_sdc);
}

const lanewise =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "sel": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [20, 21]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [30, 31], "Q": [10, 11]}
    \\        },
    \\        "mx": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [10, 11], "B": [10, 11], "S": [4], "Y": [12, 13]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [12, 13], "Q": [20, 21]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "wide muxes propagate lane to lane, never across" {
    var l = try loadAll(lanewise, sinks_sdc);
    defer freeAll(&l);
    try std.testing.expectEqual(@as(usize, 5), l.report.crossings.len);
    try std.testing.expect(xFor(&l, .flop_flop_bit, 10, 12) != null);
    try std.testing.expect(xFor(&l, .flop_flop_bit, 11, 13) != null);
    try std.testing.expect(xFor(&l, .flop_flop_bit, 10, 13) == null);
    try std.testing.expect(xFor(&l, .flop_flop_bit, 11, 12) == null);
}

test "mux selects record control crossings into the union" {
    var l = try loadAll(muxed_src, muxed_sdc);
    defer freeAll(&l);
    const x = xFor(&l, .clock_control, 4, 4).?;
    try std.testing.expectEqualStrings("port:sel", x.src_clk);
    try std.testing.expectEqualStrings("ca+cb", x.dst_clk);
    try std.testing.expect(x.async_per_sdc);
}

const ctl_flop =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [4]}
    \\      },
    \\      "cells": {
    \\        "fen": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        },
    \\        "gate": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [10], "Y": [11]}
    \\        },
    \\        "f": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [11], "D": [3], "Q": [4]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "flopped enables record same-domain control crossings" {
    var l = try loadAll(ctl_flop, sinks_sdc);
    defer freeAll(&l);
    const x = xFor(&l, .clock_control, 10, 10).?;
    try std.testing.expectEqualStrings("clk", x.src_clk);
    try std.testing.expectEqualStrings("clk", x.dst_clk);
    try std.testing.expect(!x.async_per_sdc);
}

const mems =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "wclk": {"direction": "input", "bits": [2]},
    \\        "rclk": {"direction": "input", "bits": [3]},
    \\        "waddr": {"direction": "input", "bits": [4]},
    \\        "wdata": {"direction": "input", "bits": [5]},
    \\        "we": {"direction": "input", "bits": [6]},
    \\        "raddr": {"direction": "input", "bits": [7]},
    \\        "q": {"direction": "output", "bits": [8]}
    \\      },
    \\      "cells": {
    \\        "wr": {
    \\          "type": "$memwr",
    \\          "port_directions": {"CLK": "input", "ADDR": "input", "DATA": "input", "EN": "input"},
    \\          "connections": {"CLK": [2], "ADDR": [4], "DATA": [5], "EN": [6]}
    \\        },
    \\        "rd": {
    \\          "type": "$memrd",
    \\          "port_directions": {"CLK": "input", "ADDR": "input", "DATA": "output", "EN": "input"},
    \\          "connections": {"CLK": [3], "ADDR": [7], "DATA": [10], "EN": ["1"]},
    \\          "parameters": {"CLK_ENABLE": "1"}
    \\        },
    \\        "rda": {
    \\          "type": "$memrd",
    \\          "port_directions": {"CLK": "input", "ADDR": "input", "DATA": "output"},
    \\          "connections": {"CLK": [3], "ADDR": [7], "DATA": [11]},
    \\          "parameters": {"CLK_ENABLE": "0"}
    \\        },
    \\        "f": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [8]}
    \\        },
    \\        "fa": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [11], "Q": [12]}
    \\        },
    \\        "blob": {
    \\          "type": "$mem",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [7], "Y": [13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const mems_sdc =
    \\create_clock -name wclk -period 10 [get_ports wclk]
    \\create_clock -name rclk -period 7 [get_ports rclk]
    \\set_clock_groups -asynchronous -group {wclk} -group {rclk}
;

test "memory ports sink and source with memory clocks" {
    var l = try loadAll(mems, mems_sdc);
    defer freeAll(&l);
    try std.testing.expectEqual(@as(usize, 12), l.report.crossings.len);
    const waddr = xFor(&l, .port_flop_untyped, 4, 4).?;
    try std.testing.expectEqualStrings("port:waddr", waddr.src_clk);
    try std.testing.expectEqualStrings("wclk", waddr.dst_clk);
    try std.testing.expect(waddr.async_per_sdc);
    const sync_rd = xFor(&l, .flop_flop_bit, 10, 10).?;
    try std.testing.expectEqualStrings("rclk", sync_rd.src_clk);
    try std.testing.expectEqualStrings("rclk", sync_rd.dst_clk);
    try std.testing.expect(!sync_rd.async_per_sdc);
    const async_rd = xFor(&l, .flop_flop_bit, 11, 11).?;
    try std.testing.expectEqualStrings("unknown", async_rd.src_clk);
    try std.testing.expect(async_rd.async_per_sdc);
    for (l.report.crossings) |x| {
        if (x.src.cell) |ci| try std.testing.expect(!std.mem.eql(u8, l.mod.cells[ci].name, "blob"));
        try std.testing.expect(!std.mem.eql(u8, l.mod.cells[x.dst.cell.?].name, "blob"));
    }
}
