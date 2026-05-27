// Gothos client — bundled backend backed by PostgreSQL entities/relationships.
// When Gothos ships as a separate service, replace with HTTP JSON-RPC calls to
// gothos_url in config. All callers go through this module — no direct DB
// access for graph queries elsewhere in the daemon.

const std = @import("std");
const c = @import("c.zig").lib;

// Resolve a project name to its id. Falls back to id=1 (first project) when
// name is null or not found. Callers that need strict project isolation should
// check the return value against -1 themselves.
pub fn resolveProject(db: *c.IcrDb, name: ?[]const u8) i64 {
    const n = name orelse return 1;
    var z: [256:0]u8 = undefined;
    const l = @min(n.len, 255);
    @memcpy(z[0..l], n[0..l]);
    z[l] = 0;
    const id = c.icr_project_lookup(db, @ptrCast(&z));
    return if (id > 0) id else 1;
}

// Copy an optional slice into a stack buffer and return a C-compatible nullable
// null-terminated pointer. Returns null when src is null.
fn toZopt(src: ?[]const u8, buf: []u8) ?[*:0]const u8 {
    const s = src orelse return null;
    const l = @min(s.len, buf.len - 1);
    @memcpy(buf[0..l], s[0..l]);
    buf[l] = 0;
    const p: [*:0]const u8 = @ptrCast(buf.ptr);
    return p;
}

// queryEntities writes a JSON array of matching entities into out and returns
// the populated slice. kind and name_pattern are optional SQL filters (ILIKE).
pub fn queryEntities(
    db: *c.IcrDb,
    project_id: i64,
    kind: ?[]const u8,
    name_pattern: ?[]const u8,
    out: []u8,
) ![]const u8 {
    var kind_buf: [64]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    const rc = c.icr_gothos_query_entities(
        db,
        project_id,
        toZopt(kind, &kind_buf),
        toZopt(name_pattern, &name_buf),
        out.ptr,
        out.len,
    );
    if (rc != 0) return error.QueryFailed;
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}

// queryRelations writes a JSON array of matching edges into out. from_name and
// rel_kind are optional filters; both null returns all relations in the project.
pub fn queryRelations(
    db: *c.IcrDb,
    project_id: i64,
    from_name: ?[]const u8,
    rel_kind: ?[]const u8,
    out: []u8,
) ![]const u8 {
    var from_buf: [256]u8 = undefined;
    var kind_buf: [64]u8 = undefined;
    const rc = c.icr_gothos_query_relations(
        db,
        project_id,
        toZopt(from_name, &from_buf),
        toZopt(rel_kind, &kind_buf),
        out.ptr,
        out.len,
    );
    if (rc != 0) return error.QueryFailed;
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}

// getContext writes a {"entities":[...],"relations":[...]} subgraph centered on
// focus_name into out. depth is accepted but only depth=1 is currently active.
pub fn getContext(
    db: *c.IcrDb,
    project_id: i64,
    focus_name: []const u8,
    depth: i32,
    out: []u8,
) ![]const u8 {
    var focus_buf: [256:0]u8 = undefined;
    const fl = @min(focus_name.len, 255);
    @memcpy(focus_buf[0..fl], focus_name[0..fl]);
    focus_buf[fl] = 0;
    const rc = c.icr_gothos_get_context(db, project_id, @ptrCast(&focus_buf), depth, out.ptr, out.len);
    if (rc != 0) return error.QueryFailed;
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}

// noCovergroup writes a JSON array of UVM_AGENT entities with no HAS_COVERGROUP
// edge into out. This is a deterministic structural query — no LLM involved.
pub fn noCovergroup(
    db: *c.IcrDb,
    project_id: i64,
    out: []u8,
) ![]const u8 {
    const rc = c.icr_gothos_no_covergroup(db, project_id, out.ptr, out.len);
    if (rc != 0) return error.QueryFailed;
    const end = std.mem.indexOfScalar(u8, out, 0) orelse out.len;
    return out[0..end];
}
