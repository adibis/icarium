// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const ir = @import("icarium").ir;
const report = @import("icarium").report;
const rule = @import("icarium").rule;

test "parseSrc reads Yosys range shapes" {
    const p = report.sarif.parseSrc("top.sv:10.3-10.20");
    try std.testing.expectEqualStrings("top.sv", p.uri);
    try std.testing.expectEqual(@as(i64, 10), p.region.?.start_line);
    try std.testing.expectEqual(@as(i64, 3), p.region.?.start_col.?);
    try std.testing.expectEqual(@as(i64, 10), p.region.?.end_line.?);
    try std.testing.expectEqual(@as(i64, 20), p.region.?.end_col.?);

    const q = report.sarif.parseSrc("/a/b/c.sv:7.1");
    try std.testing.expectEqualStrings("/a/b/c.sv", q.uri);
    try std.testing.expectEqual(@as(i64, 7), q.region.?.start_line);
    try std.testing.expectEqual(@as(i64, 1), q.region.?.start_col.?);
    try std.testing.expect(q.region.?.end_line == null);
}

test "parseSrc degrades without inventing lines" {
    const bare = report.sarif.parseSrc("top.sv:42");
    try std.testing.expectEqualStrings("top.sv", bare.uri);
    try std.testing.expectEqual(@as(i64, 42), bare.region.?.start_line);
    try std.testing.expect(bare.region.?.start_col == null);

    const junk = report.sarif.parseSrc("not-a-src");
    try std.testing.expectEqualStrings("not-a-src", junk.uri);
    try std.testing.expect(junk.region == null);

    const badnum = report.sarif.parseSrc("top.sv:x.y-z.w");
    try std.testing.expectEqualStrings("top.sv:x.y-z.w", badnum.uri);
    try std.testing.expect(badnum.region == null);
}

const netlist =
    \\{
    \\  "modules": {
    \\    "top": {
    \\      "ports": {
    \\        "clk": {"direction": "input", "bits": [2]},
    \\        "d": {"direction": "input", "bits": [3]},
    \\        "q": {"direction": "output", "bits": [12]}
    \\      },
    \\      "cells": {
    \\        "u_blk.$procdff$1": {
    \\          "type": "$dff",
    \\          "attributes": {"src": "top.sv:10.3-10.20"},
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [3], "Q": [11]}
    \\        },
    \\        "$procdff$2": {
    \\          "type": "$dff",
    \\          "port_directions": {"CLK": "input", "D": "input", "Q": "output"},
    \\          "connections": {"CLK": [2], "D": [11], "Q": [12]}
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "sarif golden" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    var fs = [_]rule.finding.Finding{
        .{ .rule = "CDC-001", .severity = .err, .dst = "u_blk.$procdff$1", .driver = "$procdff$2", .message = "m1" },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try report.sarif.writeSarif(std.testing.allocator, &aw.writer, &mod, &fs, "0.1.0-dev");
    const want = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{golden});
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, aw.written());
}

const golden =
    \\{
    \\  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    \\  "version": "2.1.0",
    \\  "runs": [
    \\    {
    \\      "tool": {
    \\        "driver": {
    \\          "name": "icarium",
    \\          "version": "0.1.0-dev",
    \\          "rules": [
    \\            {
    \\              "id": "CDC-001",
    \\              "name": "CDC-001",
    \\              "shortDescription": {
    \\                "text": "Unsynchronized control crossing"
    \\              },
    \\              "fullDescription": {
    \\                "text": "The destination flop has no follow-on synchronizer in its own\nclock: a single-bit signal lands and is used directly, with no\nsecond stage to filter metastability. Add a 2FF chain, or assert\n(* cdc_sync *) on a vetted synchronizer, (* cdc_static *) on a\nsource held constant, (* cdc_handshake *) on a capture register."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-002",
    \\              "name": "CDC-002",
    \\              "shortDescription": {
    \\                "text": "Insufficient synchronizer depth"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A synchronizer chain exists but is shorter than the site minimum\n(--sync-depth, default 2): raise the depth or lower the bar.\nSilent at the default unless a project explicitly requires more."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-003",
    \\              "name": "CDC-003",
    \\              "shortDescription": {
    \\                "text": "Combinational logic on the way to a synchronizer"
    \\              },
    \\              "fullDescription": {
    \\                "text": "Source-domain signals combine through a gate before the\nsynchronizer: the gate can glitch across source cycles and a\n2FF cannot filter the transient. Synchronize each source bit\nfirst, then combine in the destination domain."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-004",
    \\              "name": "CDC-004",
    \\              "shortDescription": {
    \\                "text": "Multi-bit bus crossing without gating or gray-coding"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A multi-bit path crosses domains with no coherence mechanism:\nlanes settle on different cycles, so the destination can sample\na value never sent. Gate the bus behind a synchronized enable,\ngray-code it into a multi-bit chain, or assert the promise."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-005",
    \\              "name": "CDC-005",
    \\              "shortDescription": {
    \\                "text": "Reconvergent synchronizers"
    \\              },
    \\              "fullDescription": {
    \\                "text": "One source flop fans out to independent synchronizer chains\nwhose outputs recombine downstream: each chain resolves\nmetastability on its own cycle, so the recombination can see\na value pair never true at the source. Synchronize once and\nfan out after, or prove the skew harmless."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-006",
    \\              "name": "CDC-006",
    \\              "shortDescription": {
    \\                "text": "Glitchy combinational source on a control crossing"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A synchronizer first stage traces back through logic alone to\ntop-level ports, with no registering flop: the chain can sample\na transient no stable input ever held. Register the source in\nits own domain before synchronizing it."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-008",
    \\              "name": "CDC-008",
    \\              "shortDescription": {
    \\                "text": "Clock signal used as data"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A bit that drives a flop clock (or an SDC clock port) also feeds\na non-clock input: clocks ride low-skew networks and sampling\nthem as data breaks STA. Clock-distribution cells, clock pins,\nand off-chip forwarding are exempt; the rest is a wiring bug."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-009",
    \\              "name": "CDC-009",
    \\              "shortDescription": {
    \\                "text": "Pulse-width risk on fast-to-slow data crossings"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A single-bit flop crossing runs fast to slow (source period\ntimes 1.5 below the destination period) and the source flop\nis an edge detector: a 1-cycle pulse may slip between slow\nedges. Stretch the pulse, toggle it, or handshake it."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-010",
    \\              "name": "CDC-010",
    \\              "shortDescription": {
    \\                "text": "Clock mux or gate control that can emit a runt pulse"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A clock mux select or gate enable can chop the output clock\ninto runt pulses no sink synchronizer can heal. Two shapes\nfire. A control driven from a domain async to every clock the\ncell gates. And a plain mux switching between asynchronous\nclocks, whatever domain its select comes from: a select\nsynchronous to one leg still lands mid-phase on the other.\nUse a glitch-free (break-before-make) mux, or mark the select\ncdc_static if it only changes while the clocks are stopped."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-011",
    \\              "name": "CDC-011",
    \\              "shortDescription": {
    \\                "text": "Unconstrained primary input captured by clocked logic"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A top input with no set_input_delay clock typing reaches a\nflop D or SRST pin: one domain is a methodology warning, two\nor more an error no typing can silence. Type the port, then\nsynchronize the foreign side when the domains disagree."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-012",
    \\              "name": "CDC-012",
    \\              "shortDescription": {
    \\                "text": "Gated bus crossing without synced-back handshake"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A gated multi-bit crossing has no handshake holding the\npayload: the destination latches cycles after the request,\nby which time the source may have moved on. Hold the source\npayload until a synced-back ack confirms the sample."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-013",
    \\              "name": "CDC-013",
    \\              "shortDescription": {
    \\                "text": "Toggle-synchronizer event loss on fast-to-slow crossing"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A toggling source runs fast to slow past the period ratio:\ntwo toggles between destination samples cancel to zero edges\nand both events are silently lost. A handshake or\nbackpressure closes it. An XOR tail does not: it turns each\ntoggle into a pulse, but cancelled toggles never reach it.\nA toggle whose enable waits on its own acknowledgement, the\ndestination's synchronized toggle returned through a 2FF\nchain, never toggles twice between samples and is silent."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-014",
    \\              "name": "CDC-014",
    \\              "shortDescription": {
    \\                "text": "Combinational logic between synchronizer stages"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A gate sits between two stages of a synchronizer: the second\nstage may sample the first while still metastable, destroying\nthe resolution time the chain was meant to provide. Move the\ngate past the chain's final stage."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-015",
    \\              "name": "CDC-015",
    \\              "shortDescription": {
    \\                "text": "Synchronizer chain released by a foreign-domain reset"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A synchronizer chain takes its async reset from another clock\ndomain: every foreign deassertion races the chain clock, so the\nresolving flops never reach steady state. Reset the chain from\nits own domain, or synchronize the reset into it."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-016",
    \\              "name": "CDC-016",
    \\              "shortDescription": {
    \\                "text": "Opposite-edge stages in a synchronizer chain"
    \\              },
    \\              "fullDescription": {
    \\                "text": "Adjacent chain stages sample on opposite edges of one clock,\nhalving the resolution time a same-edge chain would provide.\nThe RTL reads as a symmetric 2FF, but MTBF roughly halves.\nSample every stage on the same edge."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-017",
    \\              "name": "CDC-017",
    \\              "shortDescription": {
    \\                "text": "Transparent latch in a CDC path"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A latch sits between a source flop and a destination flop in\ndifferent clocks: while the enable holds, the foreign signal\nflows transparently to the destination with no resolution\ntime. Replace the latch with a 2FF chain on the dst clock."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-018",
    \\              "name": "CDC-018",
    \\              "shortDescription": {
    \\                "text": "Cascaded synchronizer chain past the depth threshold"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A destination chain runs deeper than the threshold (default\n4): two stacked 2FF syncs, or a refactor leftover. Extra\nstages add latency without improving resolution. Trim to 2,\nraise the threshold, or vouch the head."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-019",
    \\              "name": "CDC-019",
    \\              "shortDescription": {
    \\                "text": "Independently-synced one-hot decode across CDC"
    \\              },
    \\              "fullDescription": {
    \\                "text": "One comb decoder fans to two or more 1-bit source flops that\ncross to the same domain: lanes change together upstream but\nresolve apart, so the destination can sample combinations the\nencoder never emits. Gray-code the source or handshake it."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-020",
    \\              "name": "CDC-020",
    \\              "shortDescription": {
    \\                "text": "Sliced-bus reconvergence across CDC"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A multi-bit source register fans lane by lane to two or more\ndestinations in one domain: each lane resolves apart, so the\ndestination can sample mixes the source never emits. Gray-code\nthe source, handshake it, or sync the bus whole."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-021",
    \\              "name": "CDC-021",
    \\              "shortDescription": {
    \\                "text": "Flop clock driven by an undeclared port"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A top-level input port drives flop clocks with no create_clock\nbehind it. Undeclared clocks appear in no async group, so every\nother check touching the domain silently skips. Declare it."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-022",
    \\              "name": "CDC-022",
    \\              "shortDescription": {
    \\                "text": "Synchronizer primitive shallower than required depth"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A CDC macro carries its stage count as a parameter, not a flop\nchain, so CDC-002 cannot see it. Under a project minimum the\ninstance reads short. Raise the parameter or lower the bar."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-023",
    \\              "name": "CDC-023",
    \\              "shortDescription": {
    \\                "text": "Clock net driven by a combine of declared clocks"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A gate mixes two or more declared clocks onto one net: the net\nglitches, runs at no declared frequency, and leaves its flops\ndomainless. Gate one clock, or mux instead of mixing."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-024",
    \\              "name": "CDC-024",
    \\              "shortDescription": {
    \\                "text": "Single source fanning to multiple synchronizers"
    \\              },
    \\              "fullDescription": {
    \\                "text": "One source bit reaches two or more synchronizer chains: each\nchain resolves metastability on its own edge, so the set only\nholds when the destinations never recombine what they latched\napart. CDC-005 proves the recombination; this rule flags the\nfanout itself for the independence judgement."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-025",
    \\              "name": "CDC-025",
    \\              "shortDescription": {
    \\                "text": "Unresolved clock association"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A crossing endpoint has no clock association: undriven flop\nclock, macro or memory output, unhandled primitive, or an\nuntyped input the other port rules do not own. One finding\nper endpoint names the reason and the fanout; per-pair sync\nverdicts on unclocked endpoints would be noise. Type the\nsource, model the macro, or waive after review."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "CDC-026",
    \\              "name": "CDC-026",
    \\              "shortDescription": {
    \\                "text": "Multiclock crossing leg-pair report"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A crossing whose source or receiver runs on a muxed clock:\neach side may arrive on several legs, and one leg pair can be\nsafe while another is not. One finding per endpoint lists the\nclock sets, the mux selections behind them, every leg pair with\nits relationship, and the destination chain depth. Multiple\nclocks alone prove nothing; review the pairs, then waive or fix."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "note"
    \\              }
    \\            },
    \\            {
    \\              "id": "RDC-001",
    \\              "name": "RDC-001",
    \\              "shortDescription": {
    \\                "text": "Async reset released from a foreign clock domain"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A flop's async reset fans in from a register in another clock\ndomain: every foreign deassertion races the local clock, so\nthe flop never reaches a clean out-of-reset state. Reset it\nfrom its own domain's tree, or synchronize the reset across."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "RDC-002",
    \\              "name": "RDC-002",
    \\              "shortDescription": {
    \\                "text": "Reset polarity mismatch on async reset distribution"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A flop's async reset disagrees with its source: a producer\nflop drives a value the consumer never treats as assert, or a\nport declaration contradicts the pin. The consumer never\nenters reset when the source does. Add an inverter, or fix\nthe edge to match the declaration."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "RDC-003",
    \\              "name": "RDC-003",
    \\              "shortDescription": {
    \\                "text": "Sync reset driven from a foreign async domain"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A flop's synchronous reset fans in from a register in another\nclock domain. The sync reset samples on the destination edge,\nso a foreign source turns deassertion into a metastability\nlottery. Synchronize the reset into the consumer domain."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "RDC-004",
    \\              "name": "RDC-004",
    \\              "shortDescription": {
    \\                "text": "Async reset driven by combinational logic"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A flop's async reset pin is a comb gate's output fed by flops.\nGate outputs glitch on near-simultaneous input changes, and on\nan async reset pin the transient reads as a real assertion.\nRegister the gate on the consumer clock first."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "RDC-005",
    \\              "name": "RDC-005",
    \\              "shortDescription": {
    \\                "text": "Async reset from multiple independent sources"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A flop's async reset combines two or more top-level ports with\nno flop behind the gate. Independent board sources release at\nindependent times; the consumer's release edge is undefined.\nQualify the sources through one reset tree."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "RDC-006",
    \\              "name": "RDC-006",
    \\              "shortDescription": {
    \\                "text": "Muxed async reset without a local synchronizer"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A flop's async reset is driven directly by a mux: selection\nis explicit, but the selected leg still deasserts async to\nthe consumer clock. Pipe the mux through a 2FF reset\nsynchronizer in the consumer domain. Warning, not error:\nthe block may legitimately consume an upstream-synced reset."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "warning"
    \\              }
    \\            },
    \\            {
    \\              "id": "RDC-007",
    \\              "name": "RDC-007",
    \\              "shortDescription": {
    \\                "text": "Reset synchronizer chain loads the asserted value"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A reset synchronizer chain whose head D ties to the asserted\nvalue never deasserts: on release it reloads assertion and\nholds every downstream consumer in reset forever. Tie the\nhead D to the deasserted value: 1'b1 for active-low resets."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "RDC-008",
    \\              "name": "RDC-008",
    \\              "shortDescription": {
    \\                "text": "Primary reset port unsynchronized in one domain"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A top-level reset port fans straight into flops of a domain\nwith no reset synchronizer, while another domain syncs the\nsame port: the builder knew, then missed a domain. Sync the\nport in every consuming domain. Silent when every domain\nuses the raw port; that simplification is a separate review."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "RDC-009",
    \\              "name": "RDC-009",
    \\              "shortDescription": {
    \\                "text": "Unqualified data crossing reset domains"
    \\              },
    \\              "fullDescription": {
    \\                "text": "A flop's data input is driven from another reset domain with\nno shared release: the source can come out of reset while the\nreceiver samples. Both sides need an async reset to trip it;\na side with none never releases, so unreset storage fed from\na reset domain stays silent. Clocks do not matter here."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            },
    \\            {
    \\              "id": "RDC-010",
    \\              "name": "RDC-010",
    \\              "shortDescription": {
    \\                "text": "Reset synchronizer chain record and checks"
    \\              },
    \\              "fullDescription": {
    \\                "text": "Every recognized reset synchronizer is recorded for review:\nstages, clock, polarity, head constant, async root. Shape\ndefects report beside the record: a chain on the wrong clock\nfor its consumers, internal taps feeding resets, and gates\nediting the output all break the release contract; consumers\non the raw root in a served domain report at warn."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "note"
    \\              }
    \\            },
    \\            {
    \\              "id": "RDC-011",
    \\              "name": "RDC-011",
    \\              "shortDescription": {
    \\                "text": "One net drives both sync and async resets"
    \\              },
    \\              "fullDescription": {
    \\                "text": "One resolved reset root reaches an async pin on some flop\nand a sync control ($sdff SRST or a const-leg D-mux) on\nanother. Async users leave reset on the net's edge while\nsync users wait for a clock, so the groups skew and their\nhandoff corrupts. Split the net or qualify one side."
    \\              },
    \\              "defaultConfiguration": {
    \\                "level": "error"
    \\              }
    \\            }
    \\          ]
    \\        }
    \\      },
    \\      "results": [
    \\        {
    \\          "ruleId": "CDC-001",
    \\          "level": "error",
    \\          "message": {
    \\            "text": "m1"
    \\          },
    \\          "locations": [
    \\            {
    \\              "physicalLocation": {
    \\                "artifactLocation": {
    \\                  "uri": "top.sv"
    \\                },
    \\                "region": {
    \\                  "startLine": 10,
    \\                  "startColumn": 3,
    \\                  "endLine": 10,
    \\                  "endColumn": 20
    \\                }
    \\              },
    \\              "logicalLocations": [
    \\                {
    \\                  "fullyQualifiedName": "top/u_blk/$procdff$1"
    \\                }
    \\              ]
    \\            }
    \\          ],
    \\          "relatedLocations": [
    \\            {
    \\              "logicalLocations": [
    \\                {
    \\                  "fullyQualifiedName": "top/$procdff$2"
    \\                }
    \\              ]
    \\            }
    \\          ]
    \\        }
    \\      ]
    \\    }
    \\  ]
    \\}
;
