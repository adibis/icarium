const std = @import("std");
const clock = @import("icarium").clock;
const crossing = @import("icarium").crossing;
const ir = @import("icarium").ir;
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
    const marks = try sync.attrs.collect(std.testing.allocator, &mod);
    return .{
        .mod = mod,
        .sdc_mod = sdc_mod,
        .clock_asg = clock_asg,
        .report = report,
        .table = table,
        .marks = marks,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
}

fn freeAll(l: *Loaded) void {
    l.arena.deinit();
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

const one_sdc = "create_clock -name clk -period 10 [get_ports clk]\n";
const one_sdc_typed = "create_clock -name clk -period 10 [get_ports clk]\nset_input_delay -clock clk 1.0 [get_ports d]\n";

const clk_as_data =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "div": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [10], "Q": [10]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [10], "D": [11], "Q": [12]}
    \\        },
    \\        "spy": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [3], "Y": [11]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a divided clock sampled as data fires CDC-008 alone" {
    var l = try loadAll(clk_as_data, one_sdc_typed);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "CDC-008"));
    try std.testing.expectEqual(rule.registry.Severity.err, fs[0].severity);
    try std.testing.expect(std.mem.indexOf(u8, fs[0].message, "used as data") != null);
}

const gated_clean =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "en": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "g": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [3], "Y": [10]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [10], "D": [4], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const gated_clean_sdc = "create_clock -name clk -period 10 [get_ports clk]\nset_input_delay -clock clk 1.0 [get_ports d]\nset_input_delay -clock clk 1.0 [get_ports en]\n";

test "clock-network cells never read as data use" {
    var l = try loadAll(gated_clean, gated_clean_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
}

const port_sink =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [10]}
    \\      },
    \\      "cells": {
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "one untyped port in one domain warns CDC-011 alone" {
    var l = try loadAll(port_sink, one_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "CDC-011"));
    try std.testing.expectEqual(rule.registry.Severity.warn, fs[0].severity);
    var t = try loadAll(port_sink, one_sdc_typed);
    defer freeAll(&t);
    const tfs = try checkAll(&t);
    try std.testing.expectEqual(@as(usize, 0), tfs.len);
}

const port_fanout =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "qa": {"direction": "output", "bits": [10]},
    \\        "qb": {"direction": "output", "bits": [11]}
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
    \\          "connections": {"CLK": [3], "D": [4], "Q": [11]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const fanout_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
;

test "one untyped port in two domains errors once" {
    var l = try loadAll(port_fanout, fanout_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "CDC-011"));
    try std.testing.expectEqual(rule.registry.Severity.err, fs[0].severity);
    try std.testing.expect(std.mem.indexOf(u8, fs[0].message, "multiple clock domains") != null);
}

const srst_sink =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "r": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [10]}
    \\      },
    \\      "cells": {
    \\        "dst": {
    \\          "type": "$sdff",
    \\          "port_directions": {"CLK": "input", "SRST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "SRST": [4], "D": [3], "Q": [10]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const srst_sink_sdc = "create_clock -name clk -period 10 [get_ports clk]\nset_input_delay -clock clk 1.0 [get_ports d]\n";

test "untyped sync resets count as captures" {
    var l = try loadAll(srst_sink, srst_sink_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "CDC-011"));
}

const arst_sink =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "r": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [10]}
    \\      },
    \\      "cells": {
    \\        "dst": {
    \\          "type": "$adff",
    \\          "port_directions": {"CLK": "input", "ARST": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "ARST": [4], "D": [3], "Q": [10]},
    \\          "parameters": {"ARST_POLARITY": "1"}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "async resets stay out of CDC-011" {
    var l = try loadAll(arst_sink, srst_sink_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
}

const comb_src =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "p1": {"direction": "input", "bits": [4]},
    \\        "p2": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "g": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [4], "B": [5], "Y": [10]}
    \\        },
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [11]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [11], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const comb_src_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports p1]
    \\set_input_delay -clock ca 1.0 [get_ports p2]
;

const comb_src_same =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock cb 1.0 [get_ports p1]
    \\set_input_delay -clock cb 1.0 [get_ports p2]
;

test "unregistered foreign ports before a chain fire CDC-006" {
    var l = try loadAll(comb_src, comb_src_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "CDC-006"));
    try std.testing.expect(std.mem.indexOf(u8, fs[0].message, "p1 (clock=ca)") != null);

    var s = try loadAll(comb_src, comb_src_same);
    defer freeAll(&s);
    const sfs = try checkAll(&s);
    try std.testing.expectEqual(@as(usize, 0), sfs.len);

    var u = try loadAll(comb_src, fanout_sdc);
    defer freeAll(&u);
    const ufs = try checkAll(&u);
    try std.testing.expectEqual(@as(usize, 2), ufs.len);
    for (ufs) |f| try std.testing.expectEqualStrings("CDC-011", f.rule);
}

const mux_ctl =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "cc": {"direction": "input", "bits": [4]},
    \\        "en_d": {"direction": "input", "bits": [5]},
    \\        "d": {"direction": "input", "bits": [6]},
    \\        "q": {"direction": "output", "bits": [7]}
    \\      },
    \\      "cells": {
    \\        "enf": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [4], "D": [5], "Q": [10]}
    \\        },
    \\        "mx": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [3], "S": [10], "Y": [11]}
    \\        },
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [6], "Q": [13]}
    \\        },
    \\        "f": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [11], "D": [13], "Q": [12]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [11], "D": [12], "Q": [7]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const mux_ctl_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\create_clock -name cc -period 11 [get_ports cc]
    \\set_clock_groups -asynchronous -group {ca} -group {cb} -group {cc}
    \\set_input_delay -clock cc 1.0 [get_ports en_d]
    \\set_input_delay -clock ca 1.0 [get_ports d]
;

test "a select async to every gated clock fires CDC-010" {
    var l = try loadAll(mux_ctl, mux_ctl_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "CDC-010"));
    try std.testing.expect(std.mem.indexOf(u8, fs[0].message, "control pin S") != null);
}

const mux_shared =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "en_d": {"direction": "input", "bits": [5]},
    \\        "d": {"direction": "input", "bits": [6]},
    \\        "q": {"direction": "output", "bits": [7]}
    \\      },
    \\      "cells": {
    \\        "enf": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [5], "Q": [10]}
    \\        },
    \\        "mx": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [3], "S": [10], "Y": [11]}
    \\        },
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [6], "Q": [13]}
    \\        },
    \\        "f": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [11], "D": [13], "Q": [12]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [11], "D": [12], "Q": [7]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const mux_shared_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock cb 1.0 [get_ports en_d]
    \\set_input_delay -clock ca 1.0 [get_ports d]
;

test "a select sharing a gated clock stays silent" {
    var l = try loadAll(mux_shared, mux_shared_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
}

const mux_portsel =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "sel": {"direction": "input", "bits": [10]},
    \\        "d": {"direction": "input", "bits": [6]},
    \\        "q": {"direction": "output", "bits": [7]}
    \\      },
    \\      "cells": {
    \\        "mx": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [2], "B": [3], "S": [10], "Y": [11]}
    \\        },
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [6], "Q": [13]}
    \\        },
    \\        "f": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [11], "D": [13], "Q": [12]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [11], "D": [12], "Q": [7]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const mux_portsel_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports sel]
    \\set_input_delay -clock ca 1.0 [get_ports d]
;

test "a port-driven select is not a wrong-domain flop" {
    var l = try loadAll(mux_portsel, mux_portsel_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
}

const fast_pulse =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "fc": {"direction": "input", "bits": [2]},
    \\        "sc": {"direction": "input", "bits": [3]},
    \\        "stim": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [5]}
    \\      },
    \\      "cells": {
    \\        "req": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "reqd": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [10], "Q": [11]}
    \\        },
    \\        "inv": {
    \\          "type": "$not",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [11], "Y": [12]}
    \\        },
    \\        "pe": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [12], "Y": [13]}
    \\        },
    \\        "pulse": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [13], "Q": [14]}
    \\        },
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [14], "Q": [15]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [15], "Q": [5]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const fast_pulse_sdc =
    \\create_clock -name fc -period 4 [get_ports fc]
    \\create_clock -name sc -period 10 [get_ports sc]
    \\set_clock_groups -asynchronous -group {fc} -group {sc}
    \\set_input_delay -clock fc 1.0 [get_ports stim]
;

const slow_ratio_sdc =
    \\create_clock -name fc -period 8 [get_ports fc]
    \\create_clock -name sc -period 10 [get_ports sc]
    \\set_clock_groups -asynchronous -group {fc} -group {sc}
    \\set_input_delay -clock fc 1.0 [get_ports stim]
;

test "an edge detector into a slow domain warns CDC-009" {
    var l = try loadAll(fast_pulse, fast_pulse_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "CDC-009"));
    try std.testing.expectEqual(rule.registry.Severity.warn, fs[0].severity);
    try std.testing.expect(std.mem.indexOf(u8, fs[0].message, "may not be captured") != null);

    var s = try loadAll(fast_pulse, slow_ratio_sdc);
    defer freeAll(&s);
    const sfs = try checkAll(&s);
    try std.testing.expectEqual(@as(usize, 0), sfs.len);
}

const bare_bus =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4, 5]},
    \\        "q": {"direction": "output", "bits": [12, 13]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4, 5], "Q": [10, 11]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10, 11], "Q": [12, 13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const bare_bus_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports d]
;

test "an unprotected bus fires CDC-004 once, never per lane" {
    var l = try loadAll(bare_bus, bare_bus_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "CDC-004"));
    try std.testing.expect(std.mem.indexOf(u8, fs[0].message, "2-bit path") != null);
}

const mux_gated =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4, 5]},
    \\        "go": {"direction": "input", "bits": [6]},
    \\        "q": {"direction": "output", "bits": [14, 15]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4, 5], "Q": [10, 11]}
    \\        },
    \\        "enf": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [6], "Q": [12]}
    \\        },
    \\        "gmux": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [14, 15], "B": [10, 11], "S": [12], "Y": [13, 16]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [13, 16], "Q": [14, 15]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const mux_gated_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports d]
    \\set_input_delay -clock cb 1.0 [get_ports go]
;

test "a mux-gated bus clears CDC-004 but warns CDC-012" {
    var l = try loadAll(mux_gated, mux_gated_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "CDC-012"));
}

const gray_bus =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4, 5]},
    \\        "q": {"direction": "output", "bits": [18, 19]}
    \\      },
    \\      "cells": {
    \\        "bin": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4, 5], "Q": [10, 11]}
    \\        },
    \\        "gx": {
    \\          "type": "$xor",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10, 11], "B": [11, "0"], "Y": [12, 13]}
    \\        },
    \\        "g": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [12, 13], "Q": [14, 15]}
    \\        },
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [14, 15], "Q": [16, 17]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [16, 17], "Q": [18, 19]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a gray-coded bus into a multi-bit chain clears CDC-004" {
    var l = try loadAll(gray_bus, bare_bus_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
}

const marked_gray =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4, 5]},
    \\        "q": {"direction": "output", "bits": [12, 13]}
    \\      },
    \\      "netnames": {
    \\        "src_q": {"bits": [10, 11], "attributes": {"cdc_gray": 1}}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4, 5], "Q": [10, 11]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10, 11], "Q": [12, 13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a user-vouched gray source clears CDC-004" {
    var l = try loadAll(marked_gray, bare_bus_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
}

const gate_between =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "m": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [6]}
    \\        },
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [6], "Q": [7]}
    \\        },
    \\        "mask": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [5], "Q": [8]}
    \\        },
    \\        "g": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [7], "B": [8], "Y": [9]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [9], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const gate_between_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports d]
    \\set_input_delay -clock cb 1.0 [get_ports m]
;

test "a gate between stages fires CDC-014 alone" {
    var l = try loadAll(gate_between, gate_between_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "CDC-014"));
}

const toggle_fast =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "fc": {"direction": "input", "bits": [2]},
    \\        "sc": {"direction": "input", "bits": [3]},
    \\        "en": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "tog": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [5], "Q": [6]}
    \\        },
    \\        "nt": {
    \\          "type": "$not",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [6], "Y": [7]}
    \\        },
    \\        "tm": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [6], "B": [7], "S": [4], "Y": [5]}
    \\        },
    \\        "m": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [6], "Q": [8]}
    \\        },
    \\        "s": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [8], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const toggle_fast_sdc =
    \\create_clock -name fc -period 2 [get_ports fc]
    \\create_clock -name sc -period 20 [get_ports sc]
    \\set_clock_groups -asynchronous -group {fc} -group {sc}
    \\set_input_delay -clock fc 1.0 [get_ports en]
;

test "a fast toggle without an XOR tail fires CDC-013 alone" {
    var l = try loadAll(toggle_fast, toggle_fast_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expect(onlyRule(fs, "CDC-013"));
}

const gray_gated =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4, 5]},
    \\        "go": {"direction": "input", "bits": [6]},
    \\        "q": {"direction": "output", "bits": [14, 15]}
    \\      },
    \\      "cells": {
    \\        "bin": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4, 5], "Q": [7, 8]}
    \\        },
    \\        "gx": {
    \\          "type": "$xor",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [7, 8], "B": [8, "0"], "Y": [9, 17]}
    \\        },
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [9, 17], "Q": [10, 11]}
    \\        },
    \\        "enf": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [6], "Q": [12]}
    \\        },
    \\        "gmux": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [14, 15], "B": [10, 11], "S": [12], "Y": [13, 16]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [13, 16], "Q": [14, 15]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a gated gray bus clears both CDC-004 and CDC-012" {
    var l = try loadAll(gray_gated, mux_gated_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
}
