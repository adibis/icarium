// Hook system — fire-and-forget lifecycle notifications to registered capability plugins.
// Hooks are delivered synchronously within the daemon (no goroutines, no spawn).
// The kanban plugin registers handlers here at startup.

const std = @import("std");

const log = std.log.scoped(.hooks);

pub const HookFn = *const fn (payload: []const u8) void;

const HookEntry = struct {
    name: []const u8,
    handler: HookFn,
};

var g_hooks: [64]HookEntry = undefined;
var g_hooks_len: usize = 0;

pub fn register(name: []const u8, handler: HookFn) void {
    if (g_hooks_len >= g_hooks.len) {
        log.warn("hook table full, skipping: {s}", .{name});
        return;
    }
    g_hooks[g_hooks_len] = .{ .name = name, .handler = handler };
    g_hooks_len += 1;
}

pub fn fire(name: []const u8, payload: []const u8) void {
    for (g_hooks[0..g_hooks_len]) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.handler(payload);
        }
    }
}
