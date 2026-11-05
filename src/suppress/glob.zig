const std = @import("std");

// Glob-over-hierarchy for waiver patterns: `*` spans any run
// (slashes included), `?` one character. No character classes;
// waiver authors reach for longer prefixes instead.
pub fn match(pattern: []const u8, text: []const u8) bool {
    var px: usize = 0;
    var tx: usize = 0;
    var star: ?usize = null;
    var back: usize = 0;
    while (tx < text.len) {
        if (px < pattern.len and (pattern[px] == '?' or pattern[px] == text[tx])) {
            px += 1;
            tx += 1;
        } else if (px < pattern.len and pattern[px] == '*') {
            star = px;
            px += 1;
            back = tx;
        } else if (star) |s| {
            px = s + 1;
            back += 1;
            tx = back;
        } else {
            return false;
        }
    }
    while (px < pattern.len and pattern[px] == '*') px += 1;
    return px == pattern.len;
}
