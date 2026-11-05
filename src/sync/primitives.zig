const std = @import("std");
const ir = @import("../ir.zig");

// Sanctioned CDC synchroniser macros, recognised by module name.
// Real designs instantiate vendor macros (Xilinx XPM, UG974) whose
// bodies ship outside the project RTL: the analyzer sees a dual-
// clock blackbox. The name is the contract, so recognition keys
// off it; depth checks then read parameters, not flop chains.
pub const xpm_modules = std.StaticStringMap(void).initComptime(.{
    .{ "xpm_cdc_single", {} },
    .{ "xpm_cdc_array_single", {} },
    .{ "xpm_cdc_gray", {} },
    .{ "xpm_cdc_handshake", {} },
    .{ "xpm_cdc_pulse", {} },
    .{ "xpm_cdc_sync_rst", {} },
    .{ "xpm_cdc_async_rst", {} },
});

pub const xpm_default_sync_ff: i64 = 4;

// Yosys decorates parameterised modules ($paramod\name\...) and
// escapes identifiers with a backslash; the registry lookup
// needs the plain module name underneath both.
pub fn normaliseType(module_type: []const u8) []const u8 {
    var t = module_type;
    if (std.mem.startsWith(u8, t, "$paramod")) {
        var parts = std.mem.splitScalar(u8, t, '\\');
        _ = parts.next();
        if (parts.next()) |name| t = name;
    }
    var i: usize = 0;
    while (i < t.len and t[i] == '\\') : (i += 1) {}
    return t[i..];
}

pub fn isXpmPrimitive(module_type: []const u8) bool {
    return xpm_modules.get(normaliseType(module_type)) != null;
}

// A recognised macro, XPM or site-registered via --sync-primitive.
// Outputs of one are synchronised by construction, so downstream
// chain rules treat them as clean sources.
pub fn isSyncPrimitive(module_type: []const u8, extra: []const []const u8) bool {
    const name = normaliseType(module_type);
    if (xpm_modules.get(name) != null) return true;
    for (extra) |e| {
        if (std.mem.eql(u8, name, e)) return true;
    }
    return false;
}

// Every XPM macro carries DEST_SYNC_FF; only the handshake has
// a source-side SRC_SYNC_FF for the returning ack. Sorted.
pub fn depthParams(module_type: []const u8, extra: []const []const u8) []const []const u8 {
    const name = normaliseType(module_type);
    if (std.mem.eql(u8, name, "xpm_cdc_handshake")) return &[_][]const u8{ "DEST_SYNC_FF", "SRC_SYNC_FF" };
    if (xpm_modules.get(name) != null) return &[_][]const u8{"DEST_SYNC_FF"};
    for (extra) |e| {
        if (std.mem.eql(u8, name, e)) return &[_][]const u8{"DEST_SYNC_FF"};
    }
    return &[_][]const u8{};
}

pub fn syncDepth(c: ir.types.Cell, param: []const u8, xpm: bool) ?i64 {
    for (c.params) |p| {
        if (!std.mem.eql(u8, p.name, param)) continue;
        return parseParamInt(p.value);
    }
    if (xpm) return xpm_default_sync_ff;
    return null;
}

// Yosys writes integer parameters as fixed-width bit vectors;
// hand-built netlists use decimal or bare ints. All-0/1 words
// read binary first: decimal 100 there would misread badly.
pub fn parseParamInt(v: ir.types.AttrVal) ?i64 {
    switch (v) {
        .int => |i| return i,
        .str => |raw| {
            const s = std.mem.trim(u8, raw, " \t\r\n");
            if (s.len == 0) return null;
            if (s.len > 1) {
                var bits_only = true;
                for (s) |ch| {
                    if (ch != '0' and ch != '1') bits_only = false;
                }
                if (bits_only) return std.fmt.parseInt(i64, s, 2) catch null;
            }
            return std.fmt.parseInt(i64, s, 10) catch null;
        },
    }
}

// Clock-role pins on a recognised macro: XPM spells src_clk /
// dest_clk, and "clk" covers "clock" spellings for free.
pub fn isClockPin(pin: []const u8) bool {
    var lower: [64]u8 = undefined;
    if (pin.len > lower.len) return false;
    for (pin, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
    return std.mem.indexOf(u8, lower[0..pin.len], "clk") != null;
}
