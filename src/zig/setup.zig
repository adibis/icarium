const std = @import("std");
const Dir = std.Io.Dir;

const log = std.log.scoped(.icariumd);

pub const default_config =
    \\# icarium configuration — https://icarium.io/docs/configuration
    \\
    \\[indexer]
    \\# Path to indexer plugin binary (on $PATH or absolute).
    \\# Built-in NER plugin: icarium-indexer-codebert
    \\# Custom plugin: any binary that reads file paths from stdin and writes
    \\# NDJSON entity/relation records to stdout (see plugin_schema.json).
    \\plugin = "icarium-indexer-codebert"
    \\models_dir = ""   # default: ICARIUM_MODELS env, then plugin's own default
    \\
    \\[db]
    \\conninfo = "dbname=icarium host=localhost"
    \\
    \\[daemon]
    \\socket = "/tmp/icarium.sock"
    \\log_level = "info"
    \\
    \\[llm]
    \\# endpoint = "http://localhost:11434/v1"   # any OpenAI-compatible endpoint
    \\# model    = "qwen2.5-coder:32b"
    \\# endpoint = "https://api.anthropic.com/v1"
    \\# model    = "claude-sonnet-4-6"
    \\# api_key_env = "ANTHROPIC_API_KEY"
    \\
;

pub fn cmd_init(io: std.Io, ally: std.mem.Allocator, extra_args: []const []const u8) !void {
    _ = extra_args;

    const cwd = Dir.cwd();

    const exists = blk: {
        cwd.access(io, "icarium.toml", .{}) catch { break :blk false; };
        break :blk true;
    };
    if (exists) {
        log.info("icarium.toml already exists, skipping", .{});
    } else {
        var f = try cwd.createFile(io, "icarium.toml", .{});
        defer f.close(io);
        var buf: [256]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(default_config);
        try w.interface.flush();
        log.info("created icarium.toml", .{});
    }

    const cwd_path = blk: {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try cwd.realPath(io, &path_buf);
        break :blk try ally.dupe(u8, path_buf[0..n]);
    };
    defer ally.free(cwd_path);

    try install_git_hooks(io, ally, cwd_path);
    log.info("icarium initialized. Run 'icariumd start' to begin indexing.", .{});
}

fn install_git_hooks(io: std.Io, ally: std.mem.Allocator, project_root: []const u8) !void {
    const hooks_abs = try std.fmt.allocPrint(ally, "{s}/.git/hooks", .{project_root});
    defer ally.free(hooks_abs);
    Dir.accessAbsolute(io, hooks_abs, .{}) catch {
        log.warn(".git/hooks not found — skipping git hook installation", .{});
        return;
    };

    const hook_abs = try std.fmt.allocPrint(ally, "{s}/.git/hooks/post-commit", .{project_root});
    defer ally.free(hook_abs);

    var f = try Dir.createFileAbsolute(io, hook_abs, .{});
    defer f.close(io);
    var buf: [256]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(
        \\#!/bin/sh
        \\# icarium: trigger incremental index on commit
        \\icariumd index --incremental --quiet &
        \\
    );
    try w.interface.flush();
    _ = std.c.chmod(@ptrCast(hook_abs), 0o755);
    log.info("installed post-commit hook", .{});
}
