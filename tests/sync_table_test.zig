const std = @import("std");
const clock = @import("icarium").clock;
const ir = @import("icarium").ir;
const sdc = @import("icarium").sdc;
const sync = @import("icarium").sync;

const Loaded = struct {
    mod: ir.types.Module,
    sdc_mod: sdc.model.Model,
    clock_asg: clock.trace.Assignment,
    table: sync.table.Table,
    marks: sync.attrs.Marks,
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
    var table = try sync.table.build(std.testing.allocator, &mod, &clock_asg);
    errdefer table.deinit();
    const marks = try sync.attrs.collect(std.testing.allocator, &mod);
    return .{ .mod = mod, .sdc_mod = sdc_mod, .clock_asg = clock_asg, .table = table, .marks = marks };
}

fn freeAll(l: *Loaded) void {
    l.marks.deinit();
    l.table.deinit();
    l.clock_asg.deinit();
    l.sdc_mod.deinit();
    l.mod.deinit();
}

fn cellIdx(mod: *const ir.types.Module, name: []const u8) usize {
    for (mod.cells, 0..) |c, i| {
        if (std.mem.eql(u8, c.name, name)) return i;
    }
    unreachable;
}

const two_sdc = "create_clock -name clk -period 10 [get_ports clk]\n";

const chain =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [10], "Q": [11]}
    \\        },
    \\        "s3": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [11], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "chains count stages while Q stays single-reader" {
    var l = try loadAll(chain, two_sdc);
    defer freeAll(&l);
    const s1 = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "s1"), "clk");
    try std.testing.expectEqual(@as(u32, 3), s1.depth);
    try std.testing.expectEqual(@as(usize, 3), s1.stages.len);
    const s2 = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "s2"), "clk");
    try std.testing.expectEqual(@as(u32, 2), s2.depth);
    const s3 = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "s3"), "clk");
    try std.testing.expectEqual(@as(u32, 1), s3.depth);
    try std.testing.expect(l.table.hasInterStageComb(&l.mod, cellIdx(&l.mod, "s1")) == null);
}

const fanout =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [11]},
    \\        "tap": {"direction": "output", "bits": [13]}
    \\      },
    \\      "cells": {
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [10], "Q": [11]}
    \\        },
    \\        "leak": {
    \\          "type": "$not",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [10], "Y": [13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a second reader ends the chain where the value escapes" {
    var l = try loadAll(fanout, two_sdc);
    defer freeAll(&l);
    const s1 = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "s1"), "clk");
    try std.testing.expectEqual(@as(u32, 1), s1.depth);
}

const reclock =
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
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [4], "Q": [10]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [3], "D": [10], "Q": [11]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

const reclock_sdc =
    \\create_clock -name ca -period 10 [get_ports ca]
    \\create_clock -name cb -period 7 [get_ports cb]
;

test "a stage in another clock never extends the chain" {
    var l = try loadAll(reclock, reclock_sdc);
    defer freeAll(&l);
    const s1 = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "s1"), "clk");
    try std.testing.expectEqual(@as(u32, 1), s1.depth);
    const s1b = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "s1"), "ca");
    try std.testing.expectEqual(@as(u32, 1), s1b.depth);
}

const srst_chain =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "rst": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        },
    \\        "rmx": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": ["0"], "B": [10], "S": [4], "Y": [11]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [11], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "constant-leg reset muxes are stepped over, not gates" {
    var l = try loadAll(srst_chain, two_sdc);
    defer freeAll(&l);
    const s1 = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "s1"), "clk");
    try std.testing.expectEqual(@as(u32, 2), s1.depth);
    try std.testing.expect(l.table.hasInterStageComb(&l.mod, cellIdx(&l.mod, "s1")) == null);
}

const en_chain =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "en": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        },
    \\        "emx": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": [12], "B": [10], "S": [4], "Y": [11]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [11], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "enable muxes break the chain and read as gates" {
    var l = try loadAll(en_chain, two_sdc);
    defer freeAll(&l);
    const s1 = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "s1"), "clk");
    try std.testing.expectEqual(@as(u32, 1), s1.depth);
    const gate = l.table.hasInterStageComb(&l.mod, cellIdx(&l.mod, "s1"));
    try std.testing.expect(gate != null);
    try std.testing.expectEqual(cellIdx(&l.mod, "s2"), gate.?);
}

const shift_packed =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "sh": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3, 10, 11], "Q": [10, 11, 12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "packed shift registers read intra-cell depth" {
    var l = try loadAll(shift_packed, two_sdc);
    defer freeAll(&l);
    const sh = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "sh"), "clk");
    try std.testing.expectEqual(@as(u32, 3), sh.depth);
}

const packed_rst =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "rst": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "rmx": {
    \\          "type": "$mux",
    \\          "port_directions": {"A": "input", "B": "input", "S": "input", "Y": "output"},
    \\          "connections": {"A": ["0", "0", "0"], "B": [3, 10, 11], "S": [4], "Y": [20, 21, 22]}
    \\        },
    \\        "sh": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [20, 21, 22], "Q": [10, 11, 12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "packed shift registers look through their reset mux" {
    var l = try loadAll(packed_rst, two_sdc);
    defer freeAll(&l);
    const sh = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "sh"), "clk");
    try std.testing.expectEqual(@as(u32, 3), sh.depth);
}

const busreg =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3, 4]},
    \\        "q": {"direction": "output", "bits": [11, 12]}
    \\      },
    \\      "cells": {
    \\        "b1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3, 4], "Q": [11, 12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "genuine buses never read as shift registers" {
    var l = try loadAll(busreg, two_sdc);
    defer freeAll(&l);
    const b1 = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "b1"), "clk");
    try std.testing.expectEqual(@as(u32, 1), b1.depth);
}

const gated =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "sel": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        },
    \\        "g": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [4], "Y": [11]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [11], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "comb between stages is found, not counted" {
    var l = try loadAll(gated, two_sdc);
    defer freeAll(&l);
    const s1 = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "s1"), "clk");
    try std.testing.expectEqual(@as(u32, 1), s1.depth);
    const gate = l.table.hasInterStageComb(&l.mod, cellIdx(&l.mod, "s1"));
    try std.testing.expect(gate != null);
    try std.testing.expectEqual(cellIdx(&l.mod, "s2"), gate.?);
}

const marked =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [10]}
    \\      },
    \\      "netnames": {
    \\        "sync_q": {"bits": [10], "attributes": {"ASYNC_REG": "TRUE"}},
    \\        "hold_q": {"bits": [11], "attributes": {"cdc_static": 1}},
    \\        "req_q": {"bits": [12], "attributes": {"cdc_handshake": 1}},
    \\        "gray_q": {"bits": [13], "attributes": {"gray_code": 1}},
    \\        "sel_n": {"bits": [14], "attributes": {"glitchless_clock_mux": 1}}
    \\      },
    \\      "cells": {
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        },
    \\        "h1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [11]}
    \\        },
    \\        "r1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [12]}
    \\        },
    \\        "g1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "user marks resolve through netname wires to flop Q" {
    var l = try loadAll(marked, two_sdc);
    defer freeAll(&l);
    try std.testing.expect(l.marks.hasSync("s1"));
    try std.testing.expect(!l.marks.hasSync("h1"));
    try std.testing.expect(l.marks.hasStatic("h1"));
    try std.testing.expect(l.marks.hasHandshake("r1"));
    try std.testing.expect(l.marks.hasGray("g1"));
    try std.testing.expect(l.marks.glitchlessBit(14));
    try std.testing.expect(!l.marks.glitchlessBit(10));
}

const bufchain =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        },
    \\        "b1": {
    \\          "type": "$buf",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [10], "Y": [11]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [11], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "buffers between stages keep the chain whole" {
    var l = try loadAll(bufchain, two_sdc);
    defer freeAll(&l);
    const s1 = try l.table.chainDepth(&l.mod, cellIdx(&l.mod, "s1"), "clk");
    try std.testing.expectEqual(@as(u32, 2), s1.depth);
    try std.testing.expect(l.table.hasInterStageComb(&l.mod, cellIdx(&l.mod, "s1")) == null);
}

const tapgate =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "mask": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]},
    \\        "tap": {"direction": "output", "bits": [13]}
    \\      },
    \\      "cells": {
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        },
    \\        "g1": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [4], "Y": [11]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [11], "Q": [12]}
    \\        },
    \\        "leak": {
    \\          "type": "$buf",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [10], "Y": [13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a tapped head feeds logic, not an inter-stage gate" {
    var l = try loadAll(tapgate, two_sdc);
    defer freeAll(&l);
    try std.testing.expect(l.table.hasInterStageComb(&l.mod, cellIdx(&l.mod, "s1")) == null);
}

const sharedgate =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "mask": {"direction": "input", "bits": [4]},
    \\        "q": {"direction": "output", "bits": [12]},
    \\        "tap": {"direction": "output", "bits": [13]}
    \\      },
    \\      "cells": {
    \\        "s1": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [10]}
    \\        },
    \\        "g1": {
    \\          "type": "$and",
    \\          "port_directions": {"A": "input", "B": "input", "Y": "output"},
    \\          "connections": {"A": [10], "B": [4], "Y": [11]}
    \\        },
    \\        "s2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [11], "Q": [12]}
    \\        },
    \\        "leak": {
    \\          "type": "$buf",
    \\          "port_directions": {"A": "input", "Y": "output"},
    \\          "connections": {"A": [11], "Y": [13]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "a shared gate output feeds logic, not a second stage" {
    var l = try loadAll(sharedgate, two_sdc);
    defer freeAll(&l);
    try std.testing.expect(l.table.hasInterStageComb(&l.mod, cellIdx(&l.mod, "s1")) == null);
}
