// Gear registry — discovers *.gear files at startup and provides trigger matching.

const std = @import("std");
const gear = @import("gear.zig");

const log = std.log.scoped(.gears);

pub var g_gears: std.ArrayListUnmanaged(gear.Gear) = .empty;

// Load all *.gear files from dir_path. Silently skips missing directories.
pub fn loadDir(ally: std.mem.Allocator, dir_path: []const u8) !void {
    var dir_z: [4096:0]u8 = undefined;
    if (dir_path.len >= dir_z.len) return;
    @memcpy(dir_z[0..dir_path.len], dir_path);
    dir_z[dir_path.len] = 0;

    const dir = std.c.opendir(&dir_z) orelse return;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |ent| {
        if (ent.type != std.c.DT.REG) continue;
        const ename = std.mem.sliceTo(&ent.name, 0);
        if (!std.mem.endsWith(u8, ename, ".gear")) continue;

        var full: [4096]u8 = undefined;
        const fp = std.fmt.bufPrint(&full, "{s}/{s}", .{ dir_path, ename }) catch continue;

        const g = gear.load(ally, fp) catch |err| {
            log.warn("skipping {s}: {}", .{ ename, err });
            continue;
        };
        try g_gears.append(ally, g);
        log.info("gear '{s}': {d} triggers, {d} stages", .{
            g.name, g.triggers.len, g.stages.len,
        });
    }
}

// Load gears from all standard locations (env override, built-in, user dir).
pub fn loadAll(ally: std.mem.Allocator) !void {
    // 1. ICARIUM_GEARS env override
    if (std.c.getenv("ICARIUM_GEARS")) |env| {
        const p = std.mem.sliceTo(env, 0);
        try loadDir(ally, p);
    }

    // 2. ./gears/ relative to cwd (development / installed alongside binary)
    try loadDir(ally, "gears");

    // 3. ~/.icarium/gears/
    if (std.c.getenv("HOME")) |home_env| {
        const home = std.mem.sliceTo(home_env, 0);
        var user_dir: [512]u8 = undefined;
        const ud = std.fmt.bufPrint(&user_dir, "{s}/.icarium/gears", .{home}) catch "";
        if (ud.len > 0) try loadDir(ally, ud);
    }

    log.info("{d} gear(s) loaded", .{g_gears.items.len});
}

// Return the first gear whose trigger appears in query (case-insensitive).
pub fn findGear(query: []const u8) ?*const gear.Gear {
    for (g_gears.items) |*g| {
        for (g.triggers) |trigger| {
            if (containsIgnoreCase(query, trigger)) return g;
        }
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const limit = haystack.len - needle.len + 1;
    for (0..limit) |i| {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}
