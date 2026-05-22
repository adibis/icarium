const std = @import("std");
const net = std.Io.net;
const Dir = std.Io.Dir;

const c = @cImport({
    @cInclude("db.h");
});

const log = std.log.scoped(.icariumd);

pub const std_options = std.Options{
    .log_level = .info,
};

const sock_path = "/tmp/icarium.sock";
const pid_path  = "/tmp/icariumd.pid";
const default_conninfo = "dbname=icarium host=localhost";

// ── Task queue (in-memory, optionally backed by PG) ───────────────────────────

const TaskKind = enum { shell, index, triage };
const TaskState = enum { pending, running, done, failed };

const Task = struct {
    id:            u64,
    kind:          TaskKind,
    state:         TaskState,
    cmd:           []u8,         // heap-allocated
    exit_code:     i32,
    stdout_tail:   [512]u8,
    stdout_len:    usize,
    created_ns:    i64,
    completed_ns:  i64,

    fn toJson(self: *const Task, buf: []u8) []u8 {
        const state_str = switch (self.state) {
            .pending => "pending",
            .running => "running",
            .done    => "done",
            .failed  => "failed",
        };
        const kind_str = switch (self.kind) {
            .shell  => "shell",
            .index  => "index",
            .triage => "triage",
        };
        const n = std.fmt.bufPrint(buf,
            "{{\"id\":{d},\"kind\":\"{s}\",\"state\":\"{s}\",\"exit_code\":{d}}}",
            .{ self.id, kind_str, state_str, self.exit_code },
        ) catch buf[0..0];
        return n;
    }
};

// Global shared state — initialised once in cmd_start before any threads run.
var g_ally: std.mem.Allocator = undefined;
var g_mu: std.atomic.Mutex = .unlocked;
var g_tasks: std.ArrayListUnmanaged(Task) = .empty;
var g_next_id: u64 = 1;
var g_db: ?*c.IcrDb = null;   // null if PG not configured / unavailable

fn mu_lock() void {
    while (!g_mu.tryLock()) {
        std.atomic.spinLoopHint();
    }
}
fn mu_unlock() void {
    g_mu.unlock();
}

fn nanoTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + @as(i64, ts.nsec);
}

// ── Executor thread ───────────────────────────────────────────────────────────

fn executor_loop(_: void) void {
    while (true) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 500_000_000 };
        _ = std.c.nanosleep(&ts, null);

        // Find one pending task
        var maybe_idx: ?usize = null;
        mu_lock();
        for (g_tasks.items, 0..) |*t, i| {
            if (t.state == .pending) {
                t.state = .running;
                maybe_idx = i;
                break;
            }
        }
        mu_unlock();

        const idx = maybe_idx orelse continue;

        // Read cmd without holding the lock during exec
        mu_lock();
        const cmd = g_tasks.items[idx].cmd;
        const task_id = g_tasks.items[idx].id;
        mu_unlock();

        // Persist running state
        if (g_db) |db| {
            const db_id: i64 = @intCast(task_id);
            _ = c.icr_task_start(db, db_id);
        }

        // Execute
        var stdout_buf: [512]u8 = undefined;
        var exit_code: c_int = 0;
        const exec_ok = c.icr_exec_shell(cmd.ptr, &stdout_buf, stdout_buf.len, &exit_code);

        // Update task state
        mu_lock();
        if (idx < g_tasks.items.len) {
            var t = &g_tasks.items[idx];
            t.exit_code    = exit_code;
            t.state        = if (exec_ok == 0 and exit_code == 0) .done else .failed;
            t.completed_ns = nanoTimestamp();
            const slen = std.mem.indexOfScalar(u8, &stdout_buf, 0) orelse stdout_buf.len;
            t.stdout_len   = @min(slen, t.stdout_tail.len);
            @memcpy(t.stdout_tail[0..t.stdout_len], stdout_buf[0..t.stdout_len]);
        }
        const final_state  = g_tasks.items[idx].state;
        const stdout_slice = g_tasks.items[idx].stdout_tail[0..g_tasks.items[idx].stdout_len];
        mu_unlock();

        log.info("task {} finished: {} (exit={})", .{ task_id, final_state, exit_code });

        // Persist result
        if (g_db) |db| {
            const db_id: i64 = @intCast(task_id);
            var tail_z: [513]u8 = undefined;
            @memcpy(tail_z[0..stdout_slice.len], stdout_slice);
            tail_z[stdout_slice.len] = 0;
            if (final_state == .done) {
                _ = c.icr_task_done(db, db_id, exit_code, &tail_z);
            } else {
                _ = c.icr_task_fail(db, db_id, &tail_z);
            }
        }
    }
}

// ── main ─────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    g_ally = init.gpa;
    const io   = init.io;

    const args_slice = try init.minimal.args.toSlice(init.arena.allocator());

    if (args_slice.len < 2) {
        usage(args_slice[0]);
        return;
    }

    const cmd = args_slice[1];
    if (std.mem.eql(u8, cmd, "init")) {
        try cmd_init(io, g_ally, args_slice[2..]);
    } else if (std.mem.eql(u8, cmd, "start")) {
        try cmd_start(init, io);
    } else if (std.mem.eql(u8, cmd, "stop")) {
        try cmd_stop(io, g_ally);
    } else if (std.mem.eql(u8, cmd, "status")) {
        try cmd_status(init, io, g_ally);
    } else if (std.mem.eql(u8, cmd, "index")) {
        try cmd_index(g_ally, args_slice[2..]);
    } else {
        log.err("unknown command: {s}", .{cmd});
        usage(args_slice[0]);
        std.process.exit(1);
    }
}

fn usage(prog: []const u8) void {
    std.debug.print(
        \\Usage: {s} <command>
        \\
        \\Commands:
        \\  init     Initialize icarium in the current project root
        \\  start    Start the daemon (daemonizes by default)
        \\  stop     Stop a running daemon
        \\  status   Show daemon status and task queue stats
        \\  index    Trigger incremental index (called by git hook)
        \\
    , .{prog});
}

// ── init ─────────────────────────────────────────────────────────────────────

fn cmd_init(io: std.Io, ally: std.mem.Allocator, extra_args: []const []const u8) !void {
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

const default_config =
    \\# icarium configuration
    \\# https://icarium.io/docs/configuration
    \\
    \\[index]
    \\include = ["rtl", "tb", "dv", "uvm"]
    \\exclude = ["sim/work", ".git"]
    \\
    \\[models]
    \\dir = ""
    \\
    \\[daemon]
    \\socket = "/tmp/icarium.sock"
    \\log_level = "info"
    \\
    \\[db]
    \\conninfo = "dbname=icarium host=localhost"
    \\
    \\[llm]
    \\# endpoint = "http://localhost:11434/v1"
    \\# model = "qwen2.5-coder:32b"
    \\
;

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

// ── start (daemon) ────────────────────────────────────────────────────────────

fn cmd_start(init: std.process.Init, io: std.Io) !void {
    const pid1 = std.c.fork();
    if (pid1 < 0) {
        log.err("fork() failed", .{});
        std.process.exit(1);
    }
    if (pid1 > 0) return;

    _ = std.c.setsid();

    const pid2 = std.c.fork();
    if (pid2 < 0) std.process.exit(1);
    if (pid2 > 0) std.process.exit(0);

    write_pidfile(io) catch |err| log.warn("could not write PID file: {}", .{err});

    // Try to connect to PostgreSQL
    g_db = c.icr_db_open(default_conninfo);
    if (g_db) |db| {
        if (c.icr_db_migrate(db) == 0) {
            log.info("postgresql connected ({s})", .{default_conninfo});
        } else {
            log.warn("postgresql migration failed — running without persistence", .{});
        }
    } else {
        log.warn("postgresql unavailable — task queue is in-memory only", .{});
    }

    log.info("icariumd started (pid={})", .{std.c.getpid()});

    // Spawn background executor thread
    const executor_thread = try std.Thread.spawn(.{}, executor_loop, .{{}});
    executor_thread.detach();

    try run_daemon_loop(init, io);
}

fn write_pidfile(io: std.Io) !void {
    var f = try Dir.createFileAbsolute(io, pid_path, .{});
    defer f.close(io);
    var buf: [32]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.print("{d}\n", .{std.c.getpid()});
    try w.interface.flush();
}

fn run_daemon_loop(init: std.process.Init, io: std.Io) !void {
    Dir.deleteFileAbsolute(io, sock_path) catch {};

    const unix_addr = try net.UnixAddress.init(sock_path);
    var server = try unix_addr.listen(io, .{});
    defer server.deinit(io);

    log.info("listening on {s}", .{sock_path});

    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);
        handle_connection(init, io, &stream) catch |err| {
            log.warn("connection error: {}", .{err});
        };
    }
}

// ── IPC handler ───────────────────────────────────────────────────────────────

fn handle_connection(init: std.process.Init, io: std.Io, stream: *net.Stream) !void {
    _ = init;
    var read_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buf);

    var write_buf: [8192]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    const msg = try reader.interface.takeDelimiterExclusive('\n');
    const trimmed = std.mem.trim(u8, msg, &std.ascii.whitespace);

    const response = dispatch(trimmed) catch |err| blk: {
        var ebuf: [128]u8 = undefined;
        break :blk try std.fmt.bufPrint(&ebuf, "{{\"error\":\"{}\"}}", .{err});
    };

    try writer.interface.writeAll(response);
    try writer.interface.writeAll("\n");
    try writer.interface.flush();
}

// Returns a slice into a static response buffer (not thread-safe, but we're
// single-threaded in the accept loop).
fn dispatch(msg: []const u8) ![]const u8 {
    var resp_buf: [16384]u8 = undefined;

    if (matchMethod(msg, "ping")) {
        return "{\"result\":\"pong\"}";
    }

    if (matchMethod(msg, "status")) {
        mu_lock();
        var pending: usize = 0;
        var running: usize = 0;
        for (g_tasks.items) |t| {
            if (t.state == .pending) pending += 1;
            if (t.state == .running) running += 1;
        }
        const total = g_tasks.items.len;
        mu_unlock();
        return std.fmt.bufPrint(&resp_buf,
            "{{\"result\":{{\"state\":\"running\",\"tasks\":{{\"total\":{d},\"pending\":{d},\"running\":{d}}}}}}}",
            .{ total, pending, running },
        ) catch return "{\"error\":\"buf overflow\"}";
    }

    if (matchMethod(msg, "task.submit")) {
        const cmd = extractString(msg, "cmd") orelse
            return "{\"error\":\"missing cmd\"}";
        const kind_str = extractString(msg, "kind") orelse "shell";
        const kind: TaskKind = if (std.mem.eql(u8, kind_str, "index")) .index
                          else if (std.mem.eql(u8, kind_str, "triage")) .triage
                          else .shell;

        const cmd_owned = try g_ally.dupe(u8, cmd);

        mu_lock();
        const id = g_next_id;
        g_next_id += 1;
        try g_tasks.append(g_ally, .{
            .id           = id,
            .kind         = kind,
            .state        = .pending,
            .cmd          = cmd_owned,
            .exit_code    = 0,
            .stdout_tail  = undefined,
            .stdout_len   = 0,
            .created_ns   = nanoTimestamp(),
            .completed_ns = 0,
        });
        mu_unlock();

        // Also insert into PG if available
        if (g_db) |db| {
            // Need null-terminated strings for libpq
            var kind_z: [16]u8 = undefined;
            const klen = @min(kind_str.len, kind_z.len - 1);
            @memcpy(kind_z[0..klen], kind_str[0..klen]);
            kind_z[klen] = 0;

            var params_json: [512]u8 = undefined;
            const pslice = std.fmt.bufPrint(params_json[0..511], "{{\"cmd\":\"{s}\"}}", .{cmd}) catch params_json[0..0];
            params_json[pslice.len] = 0;

            var db_id: i64 = 0;
            _ = c.icr_task_insert(db, &kind_z, &params_json, &db_id);
        }

        log.info("task {} submitted: {s}", .{ id, cmd });
        return std.fmt.bufPrint(&resp_buf,
            "{{\"result\":{{\"id\":{d},\"state\":\"pending\"}}}}",
            .{id},
        ) catch return "{\"error\":\"buf overflow\"}";
    }

    if (matchMethod(msg, "task.list")) {
        mu_lock();
        defer mu_unlock();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(g_ally);
        try out.appendSlice(g_ally, "{\"result\":[");

        const start = if (g_tasks.items.len > 20) g_tasks.items.len - 20 else 0;
        for (g_tasks.items[start..], 0..) |*t, i| {
            if (i > 0) try out.append(g_ally, ',');
            var tbuf: [256]u8 = undefined;
            try out.appendSlice(g_ally, t.toJson(&tbuf));
        }
        try out.appendSlice(g_ally, "]}");

        const owned = try g_ally.dupe(u8, out.items);
        // Leak intentionally — this response lives until next connection.
        // In a long-running daemon this is fine; TODO arena per connection.
        return owned;
    }

    if (matchMethod(msg, "query")) {
        return "{\"result\":{\"note\":\"graph query not yet wired — Phase 3\"}}";
    }
    if (matchMethod(msg, "triage")) {
        return "{\"result\":{\"note\":\"triage not yet wired — Phase 3\"}}";
    }
    if (matchMethod(msg, "coverage_gaps")) {
        return "{\"result\":{\"note\":\"coverage_gaps not yet wired — Phase 3\"}}";
    }

    return "{\"error\":\"unknown method\"}";
}

fn matchMethod(msg: []const u8, method: []const u8) bool {
    // Fast prefix check: {"method":"<method>"
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"method\":\"{s}\"", .{method}) catch return false;
    return std.mem.indexOf(u8, msg, needle) != null;
}

// Extracts the value of a JSON string field by name (no full parse — handles
// simple flat JSON objects the daemon emits).
fn extractString(msg: []const u8, field: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "\"{s}\":\"", .{field}) catch return null;
    const start_idx = (std.mem.indexOf(u8, msg, key) orelse return null) + key.len;
    const end_idx = std.mem.indexOf(u8, msg[start_idx..], "\"") orelse return null;
    return msg[start_idx .. start_idx + end_idx];
}

// ── stop ──────────────────────────────────────────────────────────────────────

fn cmd_stop(io: std.Io, ally: std.mem.Allocator) !void {
    const pid_str = Dir.cwd().readFileAlloc(io, pid_path, ally, .limited(64)) catch {
        log.err("no running daemon (no PID file found)", .{});
        std.process.exit(1);
    };
    defer ally.free(pid_str);

    const pid = try std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, pid_str, &std.ascii.whitespace), 10);
    try std.posix.kill(pid, std.posix.SIG.TERM);
    Dir.cwd().deleteFile(io, pid_path) catch {};
    log.info("sent SIGTERM to daemon (pid={})", .{pid});
}

// ── status ────────────────────────────────────────────────────────────────────

fn cmd_status(init: std.process.Init, io: std.Io, ally: std.mem.Allocator) !void {
    _ = init;
    const pid_str = Dir.cwd().readFileAlloc(io, pid_path, ally, .limited(64)) catch {
        std.debug.print("icariumd: not running\n", .{});
        return;
    };
    defer ally.free(pid_str);

    const pid = std.fmt.parseInt(std.c.pid_t,
        std.mem.trim(u8, pid_str, &std.ascii.whitespace), 10) catch {
        std.debug.print("icariumd: corrupt PID file\n", .{});
        return;
    };

    std.posix.kill(pid, @enumFromInt(0)) catch {
        std.debug.print("icariumd: stale PID (pid={d} not running)\n", .{pid});
        return;
    };

    const unix_addr = net.UnixAddress.init(sock_path) catch {
        std.debug.print("icariumd: pid={d} running but address invalid\n", .{pid});
        return;
    };
    var stream = unix_addr.connect(io) catch {
        std.debug.print("icariumd: pid={d} running but socket unreachable\n", .{pid});
        return;
    };
    defer stream.close(io);

    var write_buf: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("{\"method\":\"status\"}\n");
    try writer.interface.flush();

    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const resp = try reader.interface.takeDelimiterExclusive('\n');
    std.debug.print("icariumd: pid={d} {s}\n", .{ pid, resp });
}

// ── index ─────────────────────────────────────────────────────────────────────

fn cmd_index(ally: std.mem.Allocator, args: []const []const u8) !void {
    _ = ally;
    _ = args;
    log.info("index triggered (stub — Phase 3 wires NER pipeline)", .{});
}
