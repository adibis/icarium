// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const bits = @import("bits.zig");
const path = @import("path.zig");
const types = @import("types.zig");

// Everything lands in one arena: a Module frees with a single deinit.
pub fn loadFromSlice(parent: std.mem.Allocator, bytes: []const u8, top_name: ?[]const u8) !types.Module {
    const backing = try parent.create(std.heap.ArenaAllocator);
    errdefer parent.destroy(backing);
    backing.* = std.heap.ArenaAllocator.init(parent);
    errdefer backing.deinit();
    const alloc = backing.allocator();

    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{});
    const mods = try reqObjField(root, "modules");
    const picked = try pickTop(mods, top_name);

    var cells: std.ArrayListUnmanaged(types.Cell) = .empty;
    const cells_json = try reqObjField(picked.value, "cells");
    var cit = cells_json.object.iterator();
    while (cit.next()) |entry|
        try cells.append(alloc, try parseCell(alloc, entry.key_ptr.*, entry.value_ptr.*));

    var ports: std.ArrayListUnmanaged(types.ModulePort) = .empty;
    if (picked.value.object.get("ports")) |ports_json| {
        if (ports_json != .object) return error.BadShape;
        var pit = ports_json.object.iterator();
        while (pit.next()) |entry|
            try ports.append(alloc, try parseModulePort(alloc, entry.key_ptr.*, entry.value_ptr.*));
    }

    var mod = types.Module{
        .backing = backing,
        .name = picked.name,
        .cells = try cells.toOwnedSlice(alloc),
        .ports = try ports.toOwnedSlice(alloc),
        .driver_of = .{},
        .loads_of = .{},
        .netnames = .{},
    };
    try indexConnectivity(alloc, &mod);
    try indexNetnames(alloc, &mod, picked.value);
    return mod;
}

const Picked = struct { name: []const u8, value: std.json.Value };

fn pickTop(mods: std.json.Value, top_name: ?[]const u8) !Picked {
    if (mods != .object) return error.BadShape;
    if (top_name) |want| {
        const v = mods.object.get(want) orelse return error.MissingTop;
        return .{ .name = want, .value = v };
    }
    var it = mods.object.iterator();
    if (mods.object.count() == 1) {
        const entry = it.next().?;
        return .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
    }
    // `hierarchy` marks the top it chose; blackboxes and unused
    // modules stay in the netlist beside it.
    var found: ?Picked = null;
    while (it.next()) |e| {
        if (!markedTop(e.value_ptr.*)) continue;
        if (found != null) return error.AmbiguousTop;
        found = .{ .name = e.key_ptr.*, .value = e.value_ptr.* };
    }
    return found orelse error.AmbiguousTop;
}

fn markedTop(m: std.json.Value) bool {
    if (m != .object) return false;
    const attrs = m.object.get("attributes") orelse return false;
    if (attrs != .object) return false;
    const t = attrs.object.get("top") orelse return false;
    if (t != .string) return false;
    return std.mem.indexOfScalar(u8, t.string, '1') != null;
}

fn reqObjField(v: std.json.Value, key: []const u8) !std.json.Value {
    if (v != .object) return error.BadShape;
    return v.object.get(key) orelse error.BadShape;
}

fn parseCell(alloc: std.mem.Allocator, name: []const u8, v: std.json.Value) !types.Cell {
    if (v != .object) return error.BadShape;
    const typ = try reqString(try reqObjField(v, "type"));
    const dirs = try reqObjField(v, "port_directions");
    const conns = try reqObjField(v, "connections");

    var port_list: std.ArrayListUnmanaged(types.Port) = .empty;
    var dit = dirs.object.iterator();
    while (dit.next()) |entry| {
        const dir = try types.dirFromString(try reqString(entry.value_ptr.*));
        const conn = conns.object.get(entry.key_ptr.*) orelse return error.BadShape;
        try port_list.append(alloc, .{
            .name = entry.key_ptr.*,
            .direction = dir,
            .bits = try bits.listFromJson(alloc, conn),
        });
    }

    var params: std.ArrayListUnmanaged(types.Attr) = .empty;
    if (v.object.get("parameters")) |p| try appendAttrs(alloc, &params, p);
    var attrs: std.ArrayListUnmanaged(types.Attr) = .empty;
    if (v.object.get("attributes")) |a| try appendAttrs(alloc, &attrs, a);

    var src: ?[]const u8 = null;
    for (attrs.items) |a| {
        if (std.mem.eql(u8, a.name, "src") and a.value == .str) src = a.value.str;
    }

    return .{
        .name = name,
        .type = typ,
        .ports = try port_list.toOwnedSlice(alloc),
        .params = try params.toOwnedSlice(alloc),
        .attrs = try attrs.toOwnedSlice(alloc),
        .src = src,
        // Yosys internal cells are `$`-prefixed; anything else is a
        // surviving hierarchy instance, opaque to bit-level analysis.
        .blackbox = !std.mem.startsWith(u8, typ, "$"),
        .instance_path = try path.splitInstancePath(alloc, name),
    };
}

fn parseModulePort(alloc: std.mem.Allocator, name: []const u8, v: std.json.Value) !types.ModulePort {
    if (v != .object) return error.BadShape;
    const dir = try types.dirFromString(try reqString(try reqObjField(v, "direction")));
    return .{
        .name = name,
        .direction = dir,
        .bits = try bits.listFromJson(alloc, try reqObjField(v, "bits")),
    };
}

fn reqString(v: std.json.Value) ![]const u8 {
    if (v != .string) return error.BadShape;
    return v.string;
}

fn appendAttrs(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(types.Attr), v: std.json.Value) !void {
    if (v != .object) return error.BadShape;
    var it = v.object.iterator();
    while (it.next()) |entry| {
        const val: types.AttrVal = switch (entry.value_ptr.*) {
            .integer => |i| .{ .int = i },
            .string => |s| .{ .str = s },
            else => return error.BadShape,
        };
        try out.append(alloc, .{ .name = entry.key_ptr.*, .value = val });
    }
}

fn indexConnectivity(alloc: std.mem.Allocator, mod: *types.Module) !void {
    for (mod.ports) |p| {
        for (p.bits) |b| {
            if (b != .sig) continue;
            const loc = types.Loc{ .cell = null, .port = p.name };
            switch (p.direction) {
                .input => try putDriver(alloc, mod, b.sig, loc),
                .output => try addLoad(alloc, mod, b.sig, loc),
                .inout => {
                    try putDriver(alloc, mod, b.sig, loc);
                    try addLoad(alloc, mod, b.sig, loc);
                },
            }
        }
    }
    for (mod.cells, 0..) |c, ci| {
        for (c.ports) |p| {
            for (p.bits) |b| {
                if (b != .sig) continue;
                const loc = types.Loc{ .cell = ci, .port = p.name };
                switch (p.direction) {
                    .input => try addLoad(alloc, mod, b.sig, loc),
                    .output => try putDriver(alloc, mod, b.sig, loc),
                    .inout => {
                        try addLoad(alloc, mod, b.sig, loc);
                        try putDriver(alloc, mod, b.sig, loc);
                    },
                }
            }
        }
    }
}

fn indexNetnames(alloc: std.mem.Allocator, mod: *types.Module, picked: std.json.Value) !void {
    const nns = picked.object.get("netnames") orelse return;
    if (nns != .object) return error.BadShape;
    var it = nns.object.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        if (v != .object) return error.BadShape;
        var attrs: std.ArrayListUnmanaged(types.Attr) = .empty;
        if (v.object.get("attributes")) |a| try appendAttrs(alloc, &attrs, a);
        const offset = v.object.get("offset");
        const upto = v.object.get("upto");
        try mod.netnames.put(alloc, entry.key_ptr.*, .{
            .bits = try bits.listFromJson(alloc, try reqObjField(v, "bits")),
            .attrs = try attrs.toOwnedSlice(alloc),
            .offset = if (offset != null and offset.? == .integer) offset.?.integer else 0,
            .upto = upto != null and upto.? == .integer and upto.?.integer != 0,
        });
    }
}

// First driver wins; multi-driven-bit policy belongs to tracing,
// which sees the whole picture instead of one JSON object.
fn putDriver(alloc: std.mem.Allocator, mod: *types.Module, bit: u32, loc: types.Loc) !void {
    const slot = try mod.driver_of.getOrPut(alloc, bit);
    if (!slot.found_existing) slot.value_ptr.* = loc;
}

fn addLoad(alloc: std.mem.Allocator, mod: *types.Module, bit: u32, loc: types.Loc) !void {
    const slot = try mod.loads_of.getOrPut(alloc, bit);
    if (!slot.found_existing) slot.value_ptr.* = .empty;
    try slot.value_ptr.append(alloc, loc);
}
