// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Stable IDs: SHA-256 over the record's identity, truncated to 128
// bits and hexed. Never ordinal: IDs survive reordering, frontend
// swaps for named cells, and incremental runs. Auto-named cells
// ($procdff$N) still differ across frontends — loc-normalized IDs
// are future work, not silent breakage.
pub fn compute(kind: []const u8, src: []const u8, dst: []const u8, src_clk: []const u8, dst_clk: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_][]const u8{ kind, src, dst, src_clk, dst_clk }) |part| {
        h.update(part);
        h.update(&.{0});
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    var out: [32]u8 = undefined;
    const digits = "0123456789abcdef";
    for (digest[0..16], 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0xf];
    }
    return out;
}
