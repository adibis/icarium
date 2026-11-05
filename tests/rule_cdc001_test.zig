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

fn checkAll(l: *Loaded, only: ?[]const []const u8, skip: ?[]const []const u8) ![]rule.finding.Finding {
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
    return rule.registry.runChecks(alloc, &ctx, only, skip);
}

const two_sdc_typed =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports d]
;

const two_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
;

const bare =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [11]}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [11]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "bare async pair fires with depth and endpoints" {
    var l = try loadAll(bare, two_sdc_typed);
    defer freeAll(&l);
    const fs = try checkAll(&l, null, null);
    try std.testing.expectEqual(@as(usize, 1), fs.len);
    try std.testing.expectEqualStrings("CDC-001", fs[0].rule);
    try std.testing.expectEqual(rule.registry.Severity.err, fs[0].severity);
    try std.testing.expectEqualStrings("dst", fs[0].dst);
    try std.testing.expect(std.mem.indexOf(u8, fs[0].message, "chain depth = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, fs[0].message, "flop src") != null);
}

const synced =
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

test "a second stage silences the rule" {
    var l = try loadAll(synced, two_sdc_typed);
    defer freeAll(&l);
    const fs = try checkAll(&l, null, null);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
}

const marked_dst =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [11]}
    \\      },
    \\      "netnames": {
    \\        "dst_q": {"bits": [11], "attributes": {"cdc_sync": 1}}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [11]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a vouched destination silences the rule" {
    var l = try loadAll(marked_dst, two_sdc_typed);
    defer freeAll(&l);
    const fs = try checkAll(&l, null, null);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
}

const marked_src =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [11]}
    \\      },
    \\      "netnames": {
    \\        "src_q": {"bits": [10], "attributes": {"cdc_static": 1}}
    \\      },
    \\      "cells": {
    \\        "src": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [11]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a held-constant source silences the rule" {
    var l = try loadAll(marked_src, two_sdc_typed);
    defer freeAll(&l);
    const fs = try checkAll(&l, null, null);
    try std.testing.expectEqual(@as(usize, 0), fs.len);
}

const typed_port =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "ca": {"direction": "input", "bits": [2]},
    \\        "cb": {"direction": "input", "bits": [3]},
    \\        "d": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [10]}
    \\      },
    \\      "cells": {
    \\        "dst": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [4], "Q": [10]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const typed_port_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
    \\set_clock_groups -asynchronous -group {ca} -group {cb}
    \\set_input_delay -clock ca 1.0 [get_ports d]
;

test "typed async ports fire, untyped ports defer to CDC-011" {
    var l = try loadAll(typed_port, typed_port_sdc);
    defer freeAll(&l);
    const fs = try checkAll(&l, null, null);
    try std.testing.expectEqual(@as(usize, 1), fs.len);
    try std.testing.expect(std.mem.indexOf(u8, fs[0].message, "port d") != null);

    var u = try loadAll(typed_port, two_sdc);
    defer freeAll(&u);
    const ufs = try checkAll(&u, null, null);
    try std.testing.expectEqual(@as(usize, 1), ufs.len);
    try std.testing.expectEqualStrings("CDC-011", ufs[0].rule);
}

test "only and skip filter by rule id" {
    var l = try loadAll(bare, two_sdc_typed);
    defer freeAll(&l);
    const all = try checkAll(&l, null, null);
    try std.testing.expectEqual(@as(usize, 1), all.len);
    const kept = try checkAll(&l, &.{"CDC-001"}, null);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    const dropped = try checkAll(&l, null, &.{"CDC-001"});
    try std.testing.expectEqual(@as(usize, 0), dropped.len);
    const missed = try checkAll(&l, &.{"CDC-002"}, null);
    try std.testing.expectEqual(@as(usize, 0), missed.len);
}

test "registry finds rules and stays sorted" {
    try std.testing.expect(rule.registry.find("CDC-001") != null);
    try std.testing.expect(rule.registry.find("CDC-999") == null);
    for (rule.registry.rules[0 .. rule.registry.rules.len - 1], rule.registry.rules[1..]) |a, b| {
        try std.testing.expect(std.mem.lessThan(u8, a.id, b.id));
    }
}
