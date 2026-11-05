const std = @import("std");
const rule = @import("icarium").rule;
const suppress = @import("icarium").suppress;

const prior =
    \\{
    \\  "schema_version": "1.0",
    \\  "groups": [
    \\    {
    \\      "rule": "RDC-008",
    \\      "severity": "error",
    \\      "title": "t",
    \\      "items": [
    \\        {
    \\          "dst": {"name": "b0", "kind": "cell", "instance": "", "src": null},
    \\          "driver": null,
    \\          "message": "stale deassertion edge",
    \\          "waiver": {"waiver_id": "w", "reason": "then waived", "location": null}
    \\        }
    \\      ]
    \\    }
    \\  ]
    \\}
;

test "baseline carries identical findings regardless of waiver state" {
    var base = try suppress.baseline.load(std.testing.allocator, prior);
    defer base.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fs = [_]rule.finding.Finding{
        .{ .rule = "RDC-008", .severity = .err, .dst = "b0", .message = "stale deassertion edge" },
        .{ .rule = "RDC-008", .severity = .err, .dst = "b0", .message = "stale deassertion edge (wording drifted)" },
        .{ .rule = "CDC-001", .severity = .err, .dst = "b0", .message = "stale deassertion edge" },
    };
    const kept = try suppress.baseline.partition(arena.allocator(), &fs, &base);
    try std.testing.expectEqual(@as(usize, 2), kept);
    try std.testing.expectEqualStrings("stale deassertion edge (wording drifted)", fs[0].message);
    try std.testing.expectEqualStrings("CDC-001", fs[1].rule);
}

test "baseline load rejects non-reports" {
    try std.testing.expectError(error.BadBaseline, suppress.baseline.load(std.testing.allocator, "not json"));
    try std.testing.expectError(error.BadBaseline, suppress.baseline.load(std.testing.allocator, "{\"groups\": [{\"rule\": 7}]}"));
    const no_dst = "{\"groups\": [{\"rule\": \"RDC-008\", \"items\": [{\"message\": \"m\"}]}]}";
    try std.testing.expectError(error.BadBaseline, suppress.baseline.load(std.testing.allocator, no_dst));
}
