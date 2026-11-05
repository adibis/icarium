const std = @import("std");
const ir = @import("icarium").ir;
const rule = @import("icarium").rule;
const suppress = @import("icarium").suppress;

test "glob stars span slashes, questions take one char" {
    try std.testing.expect(suppress.glob.match("*", "anything/at/all"));
    try std.testing.expect(suppress.glob.match("u_blk/*", "u_blk/$procdff$1"));
    try std.testing.expect(!suppress.glob.match("u_blk/*", "u_other/$procdff$1"));
    try std.testing.expect(suppress.glob.match("$procdff$?", "$procdff$8"));
    try std.testing.expect(!suppress.glob.match("$procdff$?", "$procdff$81"));
    try std.testing.expect(suppress.glob.match("a*b*c", "aXXbYYc"));
    try std.testing.expect(!suppress.glob.match("a*b*c", "aXXbYY"));
    try std.testing.expect(suppress.glob.match("", ""));
    try std.testing.expect(!suppress.glob.match("", "x"));
}

test "waiver load rejects malformed files" {
    const bad_schema = "{\"schema_version\": \"2.0\", \"waivers\": []}";
    try std.testing.expectError(error.BadWaivers, suppress.waivers.load(std.testing.allocator, bad_schema));
    const no_reason = "{\"schema_version\": \"1.0\", \"waivers\": [{\"id\": \"w\", \"rules\": [\"*\"]}]}";
    try std.testing.expectError(error.BadWaivers, suppress.waivers.load(std.testing.allocator, no_reason));
    const dup_ids = "{\"schema_version\": \"1.0\", \"waivers\": [{\"id\": \"w\", \"rules\": [\"*\"], \"reason\": \"a\"}, {\"id\": \"w\", \"rules\": [\"*\"], \"reason\": \"b\"}]}";
    try std.testing.expectError(error.BadWaivers, suppress.waivers.load(std.testing.allocator, dup_ids));
    const bad_date = "{\"schema_version\": \"1.0\", \"waivers\": [{\"id\": \"w\", \"rules\": [\"*\"], \"reason\": \"a\", \"expires\": \"next friday\"}]}";
    try std.testing.expectError(error.BadWaivers, suppress.waivers.load(std.testing.allocator, bad_date));
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

const waivers_doc =
    \\{
    \\  "schema_version": "1.0",
    \\  "waivers": [
    \\    {"id": "w-inst", "rules": ["CDC-001"], "dst": "inst:u_blk", "reason": "block reviewed"},
    \\    {"id": "w-name", "rules": ["RDC-006", "RDC-008"], "dst": "$procdff$*", "reason": "top cells"},
    \\    {"id": "w-drv", "rules": ["*"], "driver": "d", "reason": "driven by d"},
    \\    {"id": "w-exp", "rules": ["*"], "reason": "lapsed", "expires": "2020-05-05"},
    \\    {"id": "w-dead", "rules": ["CDC-777"], "reason": "no such rule"}
    \\  ]
    \\}
;

test "waivers match rules, names, instances, and drivers" {
    var mod = try ir.load.loadFromSlice(std.testing.allocator, netlist, null);
    defer mod.deinit();
    var loaded = try suppress.waivers.load(std.testing.allocator, waivers_doc);
    defer loaded.deinit();
    var fs = [_]rule.finding.Finding{
        .{ .rule = "CDC-001", .severity = .err, .dst = "u_blk.$procdff$1", .driver = "$procdff$2", .message = "m1" },
        .{ .rule = "RDC-006", .severity = .warn, .dst = "$procdff$2", .driver = "d", .message = "m2" },
        .{ .rule = "CDC-002", .severity = .err, .dst = "$procdff$2", .message = "m3" },
    };
    const now = suppress.waivers.Date{ .year = 2026, .month = 11, .day = 5 };
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const applied = try suppress.waivers.apply(scratch.allocator(), &mod, &fs, &loaded, now, "w.json");

    try std.testing.expectEqualStrings("w-inst", applied.hits[0].?.id);
    try std.testing.expectEqualStrings("block reviewed", applied.hits[0].?.reason);
    try std.testing.expectEqualStrings("w.json", applied.hits[0].?.location.?);
    // First match wins in file order: w-name precedes w-drv.
    try std.testing.expectEqualStrings("w-name", applied.hits[1].?.id);
    // w-drv needs a driver; m3 has none, and w-exp has lapsed.
    try std.testing.expect(applied.hits[2] == null);

    try std.testing.expectEqual(@as(usize, 2), applied.unmatched.len);
    try std.testing.expectEqualStrings("w-drv", applied.unmatched[0]);
    try std.testing.expectEqualStrings("w-dead", applied.unmatched[1]);
    try std.testing.expectEqual(@as(usize, 1), applied.expired.len);
    try std.testing.expectEqualStrings("w-exp", applied.expired[0]);
}

test "waiver expiry compares calendar dates" {
    try std.testing.expect(suppress.waivers.parseDate("2026-11-05") != null);
    try std.testing.expect(suppress.waivers.parseDate("2026-13-01") == null);
    try std.testing.expect(suppress.waivers.parseDate("2026-11-5") == null);
    try std.testing.expect(suppress.waivers.parseDate("") == null);
}
