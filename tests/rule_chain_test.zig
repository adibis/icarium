const std = @import("std");
const clock = @import("icarium").clock;
const crossing = @import("icarium").crossing;
const ir = @import("icarium").ir;
const rule = @import("icarium").rule;
const reset = @import("icarium").reset;
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
    var awarns: std.ArrayListUnmanaged(sdc.tokens.Warning) = .empty;
    var clock_asg = try clock.trace.assign(std.testing.allocator, &mod, &sdc_mod, &awarns);
    errdefer clock_asg.deinit();
    var report = try crossing.enumerate.enumerate(std.testing.allocator, &mod, &clock_asg, &sdc_mod);
    errdefer report.deinit();
    var table = try sync.table.build(std.testing.allocator, &mod, &clock_asg);
    errdefer table.deinit();
    var marks = try sync.attrs.collect(std.testing.allocator, &mod);
    errdefer marks.deinit();
    var reset_view = try reset.trace.assign(std.testing.allocator, &mod, &clock_asg, null);
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

fn checkDepth(l: *Loaded, depth: u32) ![]rule.finding.Finding {
    const alloc = l.arena.allocator();
    const buses = try rule.context.collectBuses(alloc, l.report.crossings);
    var ctx = rule.context.Context{
        .mod = &l.mod,
        .model = &l.sdc_mod,
        .crossings = l.report.crossings,
        .table = &l.table,
        .marks = &l.marks,
        .reset_view = &l.reset_view,
        .reset_syncs = &l.reset_syncs,
        .buses = buses,
        .cfg = .{ .sync_depth = depth },
        .tmp = alloc,
        .range_alloc = alloc,
        .alloc = alloc,
    };
    return rule.registry.runChecks(alloc, &ctx, null, null);
}

fn onlyRule(fs: []rule.finding.Finding, id: []const u8) bool {
    if (fs.len != 1) return false;
    return std.mem.eql(u8, fs[0].rule, id);
}

const two_sdc_typed =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports d]
    \\set_input_delay -clock ca 1.0 [get_ports d1]
    \\set_input_delay -clock ca 1.0 [get_ports d2]
    \\set_input_delay -clock cb 1.0 [get_ports rst]
;

const two_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
;

const two_stage =
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
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
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

const two_lane =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d1": {"direction": "input", "bits": [4]},
    \\        "d2": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [24]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4, 5], "Q": [10, 11]}
    \\        },
    \\        "fork": {
    \\          "type": "$or",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [10, 11], "Y": [12]}
    \\        },
    \\        "head": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [12], "Q": [20]}
    \\        },
    \\        "gate": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [20], "B": [20], "Y": [22]}
    \\        },
    \\        "tail": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [22], "Q": [24]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "identical per-lane findings collapse to one" {
    var l = try loadAll(two_lane, two_sdc_typed);
    defer freeAll(&l);
    const fired = try checkDepth(&l, 2);
    var n: usize = 0;
    for (fired) |f| {
        if (std.mem.eql(u8, f.rule, "CDC-014")) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "two stages fire CDC-002 only when the bar is raised" {
    var l = try loadAll(two_stage, two_sdc_typed);
    defer freeAll(&l);
    const silent = try checkDepth(&l, 2);
    try std.testing.expectEqual(@as(usize, 0), silent.len);
    const fired = try checkDepth(&l, 3);
    try std.testing.expect(onlyRule(fired, "CDC-002"));
    try std.testing.expectEqual(rule.registry.Severity.warn, fired[0].severity);
    try std.testing.expect(std.mem.indexOf(u8, fired[0].message, "found 2 flop(s), required >= 3") != null);
}

const gated_sync =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d1": {"direction": "input", "bits": [4]},
    \\        "d2": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [14]}
    \\      },
    \\      "cells": {
    \\        "p": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "r": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [5], "Q": [11]}
    \\        },
    \\        "g": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [11], "Y": [12]}
    \\        },
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [12], "Q": [13]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [13], "Q": [14]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a gate before the chain fires CDC-003, not CDC-001" {
    var l = try loadAll(gated_sync, two_sdc_typed);
    defer freeAll(&l);
    const fs = try checkDepth(&l, 2);
    try std.testing.expectEqual(@as(usize, 2), fs.len);
    for (fs) |f| try std.testing.expectEqualStrings("CDC-003", f.rule);
}

const rmx_sync =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "rst": {"direction": "input", "bits": [5]},
    \\        "q": {"direction": "output", "bits": [13]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "rmx": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": ["0"], "B": [10], "S": [5], "Y": [11]}
    \\        },
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [11], "Q": [12]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [12], "Q": [13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a lone reset mux on entry is part of the flop" {
    var l = try loadAll(rmx_sync, two_sdc_typed);
    defer freeAll(&l);
    const fs = try checkDepth(&l, 2);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
}

const reconv =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [16]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "a1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [11]}
    \\        },
    \\        "a2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [11], "Q": [12]}
    \\        },
    \\        "b1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [13]}
    \\        },
    \\        "b2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [13], "Q": [14]}
    \\        },
    \\        "j": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [12], "B": [14], "Y": [15]}
    \\        },
    \\        "c": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [15], "Q": [16]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "twin chains recombining fire CDC-005 beside CDC-024" {
    var l = try loadAll(reconv, two_sdc_typed);
    defer freeAll(&l);
    const fs = try checkDepth(&l, 2);
    try std.testing.expectEqual(@as(usize, 2), fs.len);
    try std.testing.expectEqualStrings("CDC-005", fs[0].rule);
    try std.testing.expectEqualStrings("CDC-024", fs[1].rule);
    try std.testing.expectEqualStrings("src", fs[0].dst);
    try std.testing.expect(std.mem.indexOf(u8, fs[0].message, "2 independent sync chains") != null);
}

const split =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "qa": {"direction": "output", "bits": [12]},
    \\        "qb": {"direction": "output", "bits": [14]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "a1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [11]}
    \\        },
    \\        "a2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [11], "Q": [12]}
    \\        },
    \\        "b1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [13]}
    \\        },
    \\        "b2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [13], "Q": [14]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "twin chains without recombination fire CDC-024 alone" {
    var l = try loadAll(split, two_sdc_typed);
    defer freeAll(&l);
    const fs = try checkDepth(&l, 2);
    try std.testing.expect(onlyRule(fs, "CDC-024"));
}
