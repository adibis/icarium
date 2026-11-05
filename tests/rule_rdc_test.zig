const std = @import("std");
const clock = @import("icarium").clock;
const crossing = @import("icarium").crossing;
const ir = @import("icarium").ir;
const reset = @import("icarium").reset;
const rule = @import("icarium").rule;
const sdc = @import("icarium").sdc;
const sync = @import("icarium").sync;

const Loaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    clock_asg: clock.trace.Assignment,
    report: crossing.enumerate.Report,
    table: sync.table.Table,
    marks: sync.attrs.Marks,
    reset_view: reset.trace.View,
    reset_syncs: reset.chains.Syncs,
    arena: std.heap.ArenaAllocator,
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
    var report = try crossing.enumerate.enumerate(std.testing.allocator, &mod, &clock_asg, &sdc_mod);
    errdefer report.deinit();
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
        .report = report,
        .table = table,
        .marks = marks,
        .reset_view = reset_view,
        .reset_syncs = reset_syncs,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
}

fn freeAll(l: *Loaded) void {
    l.arena.deinit();
    l.reset_syncs.deinit();
    l.reset_view.deinit();
    l.marks.deinit();
    l.table.deinit();
    l.report.deinit();
    l.clock_asg.deinit();
    l.sdc_mod.deinit();
    l.mod.deinit();
}

fn checkAll(l: *Loaded) ![]rule.finding.Finding {
    const alloc = l.arena.allocator();
    const buses = try rule.context.collectBuses(alloc, &l.report);
    var ctx = rule.context.Context{
        .mod = &l.mod,
        .model = &l.sdc_mod,
        .report = &l.report,
        .table = &l.table,
        .marks = &l.marks,
        .reset_view = &l.reset_view,
        .reset_syncs = &l.reset_syncs,
        .buses = buses,
        .cfg = .{},
        .alloc = alloc,
    };
    return rule.registry.runChecks(alloc, &ctx, null, null);
}

fn onlyRule(fs: []rule.finding.Finding, id: []const u8) bool {
    if (fs.len != 1) return false;
    return std.mem.eql(u8, fs[0].rule, id);
}

const two_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
;

const foreign_release =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [6]}
    \\        },
    \\        "rst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [7]}
    \\        },
    \\        "s1": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [6], "ARST": [7], "Q": [8]}
    \\        },
    \\        "s2": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [8], "ARST": [7], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const foreign_release_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports d]
;

test "a foreign-released chain fires CDC-015 and RDC-001" {
    var l = try loadAll(foreign_release, foreign_release_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expectEqual(@as(usize, 2), fs.len);
    try std.testing.expectEqualStrings("CDC-015", fs[0].rule);
    try std.testing.expectEqualStrings("RDC-001", fs[1].rule);
}

const flop_mismatch =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "rst": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [8]}
    \\      },
    \\      "cells": {
    \\        "prod": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0", "ARST_VALUE": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": ["1"], "ARST": [3], "Q": [4]}
    \\        },
    \\        "cons": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "1", "ARST_VALUE": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": ["1"], "ARST": [4], "Q": [8]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const flop_mismatch_sdc =
    \\create_clock -name clk -period 10 [get_ports clk]
    \\set_input_delay -clock clk 1.0 [get_ports rst]
;

test "a producer value mismatch fires RDC-002 alone" {
    var l = try loadAll(flop_mismatch, flop_mismatch_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "RDC-002"));
}

const port_mismatch =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "rst_n": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [6]}
    \\      },
    \\      "netnames": {
    \\        "rst_n": {"bits": [3], "attributes": {"reset_polarity": "high"}}
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

const port_mismatch_sdc =
    \\create_clock -name clk -period 10 [get_ports clk]
;

test "a declared polarity mismatch fires RDC-002 alone" {
    var l = try loadAll(port_mismatch, port_mismatch_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "RDC-002"));
}

const srst_crossing =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "kill": {"direction": "input", "bits": [4]},
    \\        "d": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [6]}
    \\        },
    \\        "dst": {
    \\          "type": "$sdff",
    \\          "parameters": {"SRST_POLARITY": "1", "SRST_VALUE": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "SRST": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [5], "SRST": [6], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const srst_crossing_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports kill]
    \\set_input_delay -clock cb 1.0 [get_ports d]
;

test "a foreign SRST pin fires RDC-003 alone" {
    var l = try loadAll(srst_crossing, srst_crossing_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "RDC-003"));
}

const mux_reset_crossing =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "kill": {"direction": "input", "bits": [4]},
    \\        "d": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [6]}
    \\        },
    \\        "rmux": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": ["0"], "B": [5], "S": [6], "Y": [7]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [7], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a foreign reset mux fires RDC-003 beside CDC-001" {
    var l = try loadAll(mux_reset_crossing, srst_crossing_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expectEqual(@as(usize, 2), fs.len);
    try std.testing.expectEqualStrings("CDC-001", fs[0].rule);
    try std.testing.expectEqualStrings("RDC-003", fs[1].rule);
}

const comb_reset =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "a": {"direction": "input", "bits": [3]},
    \\        "b": {"direction": "input", "bits": [4]},
    \\        "d": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "fa": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [6]}
    \\        },
    \\        "fb": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [7]}
    \\        },
    \\        "g": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [6], "B": [7], "Y": [8]}
    \\        },
    \\        "dst": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0", "ARST_VALUE": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [5], "ARST": [8], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const comb_reset_sdc =
    \\create_clock -name clk -period 10 [get_ports clk]
    \\set_input_delay -clock clk 1.0 [get_ports a]
    \\set_input_delay -clock clk 1.0 [get_ports b]
    \\set_input_delay -clock clk 1.0 [get_ports d]
;

test "a flopped comb reset fires RDC-004 alone" {
    var l = try loadAll(comb_reset, comb_reset_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "RDC-004"));
}

const multi_port_reset =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "rsta": {"direction": "input", "bits": [3]},
    \\        "rstb": {"direction": "input", "bits": [4]},
    \\        "d": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "g": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [3], "B": [4], "Y": [8]}
    \\        },
    \\        "dst": {
    \\          "type": "$adff",
    \\          "parameters": {"ARST_POLARITY": "0", "ARST_VALUE": "0"},
    \\          "port_directions": {"CLK": "input", "D": "input", "ARST": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [5], "ARST": [8], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const multi_port_reset_sdc =
    \\create_clock -name clk -period 10 [get_ports clk]
    \\set_input_delay -clock clk 1.0 [get_ports d]
    \\set_input_delay -clock clk 1.0 [get_ports rsta]
    \\set_input_delay -clock clk 1.0 [get_ports rstb]
;

test "a two-port comb reset fires RDC-005 alone" {
    var l = try loadAll(multi_port_reset, multi_port_reset_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "RDC-005"));
}
