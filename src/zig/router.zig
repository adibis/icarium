// Query router — tier 1 (structural) + tier 2 (trigger match).
// Tiers 3 (embedding) and 4 (LLM) are stubs returning .embedding_needed /
// .llm_needed until those phases are built.

const std = @import("std");
const gear_mod = @import("gear.zig");
const gears    = @import("gear_registry.zig");

pub const StructuralKind = enum {
    entities,
    relations,
    no_covergroup,
    context,

    pub fn name(self: StructuralKind) []const u8 {
        return switch (self) {
            .entities      => "entities",
            .relations     => "relations",
            .no_covergroup => "no_covergroup",
            .context       => "context",
        };
    }
};

pub const RouteDecision = union(enum) {
    structural:       StructuralKind,
    gear:             *const gear_mod.Gear,
    embedding_needed: void,
    llm_needed:       void,
};

// classify returns the routing decision for a natural-language query.
// Call order: structural → trigger match → embedding stub.
// Never allocates; safe to call from the single-threaded IPC loop.
pub fn classify(query: []const u8) RouteDecision {
    if (isStructural(query)) |kind| return .{ .structural = kind };
    if (gears.findGear(query)) |g|  return .{ .gear = g };
    return .embedding_needed;
}

// ── Tier 1: structural pattern matching ──────────────────────────────────────

fn isStructural(query: []const u8) ?StructuralKind {
    // Coverage-gap queries — most specific, check first.
    if (containsAnyIC(query, &.{
        "no covergroup", "missing covergroup", "coverage gap", "no_covergroup",
    })) return .no_covergroup;

    // Relation graph queries.
    if (containsAnyIC(query, &.{
        "what relations", "list relations", "show relations",
        "list edges",     "show edges",
    })) return .relations;

    // Context queries — require the word "context" plus a preposition so bare
    // occurrences of "context" in gear queries do not false-positive.
    if (containsAnyIC(query, &.{
        "context for ", "context of ", "context around ",
    })) return .context;

    // Entity list queries — explicit list-style indicators or plural entity names.
    if (containsAnyIC(query, &.{
        // generic list phrases
        "list all", "list every", "show all", "show me all",
        "how many",  "what are all", "get all", "find all", "all the ",
        // "which <plural>" patterns — specific enough to avoid false positives
        "which agents",      "which modules",    "which drivers",
        "which monitors",    "which covergroups", "which sequencers",
        "which scoreboards", "which classes",    "which packages",
        "which interfaces",
        // "all <plural>" patterns
        "all agents",     "all modules",    "all drivers",
        "all monitors",   "all covergroups", "all sequencers",
        "all scoreboards","all entities",   "all classes",
        "all packages",   "all interfaces",
    })) return .entities;

    return null;
}

// containsAnyIC returns true if query contains any needle (case-insensitive).
fn containsAnyIC(query: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIC(query, needle)) return true;
    }
    return false;
}

fn containsIC(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const limit = haystack.len - needle.len + 1;
    outer: for (0..limit) |i| {
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc))
                continue :outer;
        }
        return true;
    }
    return false;
}
