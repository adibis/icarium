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
