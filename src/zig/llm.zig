// LLM pool — synchronous HTTPS calls to Anthropic or any OpenAI-compatible endpoint.
// Supports single calls and parallel fan-out via worker threads.
// HTTP/TLS is handled by std.http.Client (Zig built-in, no external deps).

const std = @import("std");
const q   = @import("queue.zig");

const log = std.log.scoped(.llm);

pub const Backend = enum { anthropic, openai_compat };

pub const Cfg = struct {
    endpoint: []const u8,
    model:    []const u8,
    api_key:  []const u8,
    backend:  Backend,
};

pub const Request = struct {
    system:     []const u8 = "",
    user:       []const u8,
    schema:     ?[]const u8 = null, // JSON Schema string; triggers structured output
    max_tokens: u32 = 4096,
};

pub const Response = struct {
    content:       []u8, // heap-allocated, caller must ally.free()
    input_tokens:  u32,
    output_tokens: u32,
    latency_ms:    i64,
};

pub var g_cfg:   ?Cfg    = null;
pub var g_io:    std.Io  = undefined;
var     g_ready: bool    = false;

pub fn init(io: std.Io, endpoint: []const u8, model: []const u8, api_key_env: []const u8) void {
    const is_anthropic = endpoint.len == 0 or
        std.mem.indexOf(u8, endpoint, "anthropic") != null;
    const backend: Backend = if (is_anthropic) .anthropic else .openai_compat;

    g_cfg = .{
        .backend  = backend,
        .endpoint = if (endpoint.len > 0) endpoint else "https://api.anthropic.com",
        .model    = if (model.len > 0) model
                    else if (is_anthropic) "claude-sonnet-4-6" else "gpt-4o",
        .api_key  = resolveKey(api_key_env),
    };
    g_io    = io;
    g_ready = true;
    log.info("LLM: backend={s} endpoint={s} model={s}",
        .{ @tagName(backend), g_cfg.?.endpoint, g_cfg.?.model });
}

fn resolveKey(env_name: []const u8) []const u8 {
    const name = if (env_name.len > 0) env_name else "ANTHROPIC_API_KEY";
    var buf: [64:0]u8 = undefined;
    const l = @min(name.len, buf.len - 1);
    @memcpy(buf[0..l], name[0..l]);
    buf[l] = 0;
    return if (std.c.getenv(&buf)) |p| std.mem.sliceTo(p, 0) else "";
}

// call makes one synchronous HTTPS call. Response.content is heap-allocated;
// caller must free with ally.free(resp.content).
pub fn call(ally: std.mem.Allocator, cfg: Cfg, req: Request) !Response {
    if (!g_ready) return error.LlmNotInitialized;

    const t0 = @divTrunc(q.nanoTimestamp(), 1_000_000);

    // Build JSON request body into an Allocating writer
    var body_aw = std.Io.Writer.Allocating.init(ally);
    defer body_aw.deinit();
    try buildBody(&body_aw.writer, cfg, req);
    const body_bytes = body_aw.writer.buffer[0..body_aw.writer.end];

    // Endpoint URL
    const path: []const u8 = switch (cfg.backend) {
        .anthropic     => "/v1/messages",
        .openai_compat => "/v1/chat/completions",
    };
    const url = try std.fmt.allocPrint(ally, "{s}{s}", .{ cfg.endpoint, path });
    defer ally.free(url);

    // Headers — auth_buf holds "Bearer <key>" for OpenAI
    var auth_buf: [512]u8 = undefined;
    var hdrs: [3]std.http.Header = undefined;
    const n_hdrs: usize = if (cfg.backend == .anthropic) 3 else 2;
    if (cfg.backend == .anthropic) {
        hdrs[0] = .{ .name = "x-api-key",        .value = cfg.api_key };
        hdrs[1] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        hdrs[2] = .{ .name = "content-type",      .value = "application/json" };
    } else {
        hdrs[0] = .{ .name = "authorization",
                     .value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{cfg.api_key}) catch "" };
        hdrs[1] = .{ .name = "content-type", .value = "application/json" };
    }

    // HTTP call — response body captured in a second Allocating writer
    var client = std.http.Client{ .allocator = ally, .io = g_io };
    defer client.deinit();

    var resp_aw = std.Io.Writer.Allocating.init(ally);
    defer resp_aw.deinit();

    const result = try client.fetch(.{
        .location        = .{ .url = url },
        .extra_headers   = hdrs[0..n_hdrs],
        .payload         = body_bytes,
        .response_writer = &resp_aw.writer,
    });

    const t1 = @divTrunc(q.nanoTimestamp(), 1_000_000);

    const status_code = @intFromEnum(result.status);
    if (status_code < 200 or status_code >= 300) {
        const snip = resp_aw.writer.buffer[0..@min(resp_aw.writer.end, 300)];
        log.warn("LLM HTTP {d}: {s}", .{ status_code, snip });
        return error.HttpError;
    }

    const resp_bytes = resp_aw.writer.buffer[0..resp_aw.writer.end];
    return parseResponse(ally, cfg.backend, req.schema != null, resp_bytes, t1 - t0);
}

// callParallel fans N requests out to N threads; results[i] is null on failure.
pub fn callParallel(
    ally:    std.mem.Allocator,
    cfg:     Cfg,
    reqs:    []const Request,
    results: []?Response,
) !void {
    std.debug.assert(results.len == reqs.len);

    const ctxs    = try ally.alloc(ParallelCtx, reqs.len);
    defer ally.free(ctxs);
    const threads = try ally.alloc(std.Thread, reqs.len);
    defer ally.free(threads);

    for (reqs, 0..) |req, i| {
        ctxs[i] = .{ .ally = ally, .cfg = cfg, .req = req, .out = &results[i] };
        threads[i] = try std.Thread.spawn(.{}, parallelWorker, .{&ctxs[i]});
    }
    for (threads) |t| t.join();
}

const ParallelCtx = struct {
    ally: std.mem.Allocator,
    cfg:  Cfg,
    req:  Request,
    out:  *?Response,
};

fn parallelWorker(ctx: *ParallelCtx) void {
    ctx.out.* = call(ctx.ally, ctx.cfg, ctx.req) catch |err| blk: {
        log.warn("parallel LLM call failed: {}", .{err});
        break :blk null;
    };
}

// ── Request body builders ─────────────────────────────────────────────────────

fn buildBody(w: *std.Io.Writer, cfg: Cfg, req: Request) !void {
    switch (cfg.backend) {
        .anthropic     => try buildAnthropicBody(w, cfg, req),
        .openai_compat => try buildOpenAIBody(w, cfg, req),
    }
}

fn buildAnthropicBody(w: *std.Io.Writer, cfg: Cfg, req: Request) !void {
    try w.writeAll("{\"model\":\"");
    try w.writeAll(cfg.model);
    try w.print("\",\"max_tokens\":{d},\"system\":\"", .{req.max_tokens});
    try writeEscaped(w, req.system);
    try w.writeAll("\",\"messages\":[{\"role\":\"user\",\"content\":\"");
    try writeEscaped(w, req.user);
    if (req.schema) |schema| {
        try w.writeAll("\"}],\"tools\":[{\"name\":\"output\",\"description\":\"output\",\"input_schema\":");
        try w.writeAll(schema);
        try w.writeAll("}],\"tool_choice\":{\"type\":\"tool\",\"name\":\"output\"}}");
    } else {
        try w.writeAll("\"}]}");
    }
}

fn buildOpenAIBody(w: *std.Io.Writer, cfg: Cfg, req: Request) !void {
    try w.writeAll("{\"model\":\"");
    try w.writeAll(cfg.model);
    try w.writeAll("\",\"messages\":[{\"role\":\"system\",\"content\":\"");
    try writeEscaped(w, req.system);
    try w.writeAll("\"},{\"role\":\"user\",\"content\":\"");
    try writeEscaped(w, req.user);
    if (req.schema) |schema| {
        try w.writeAll("\"}],\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"output\",\"strict\":true,\"schema\":");
        try w.writeAll(schema);
        try w.writeAll("}}}");
    } else {
        try w.writeAll("\"}]}");
    }
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"'  => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
}

// ── Response parsers ──────────────────────────────────────────────────────────

fn parseResponse(
    ally:       std.mem.Allocator,
    backend:    Backend,
    has_schema: bool,
    resp:       []const u8,
    latency_ms: i64,
) !Response {
    const content: []u8 = switch (backend) {
        .anthropic => if (has_schema)
            try extractObject(ally, resp, "\"input\":")
        else
            try extractStr(ally, resp, "text"),
        .openai_compat =>
            try extractStr(ally, resp, "content"),
    };

    return .{
        .content       = content,
        .input_tokens  = extractUint(resp,
            if (backend == .anthropic) "input_tokens" else "prompt_tokens") orelse 0,
        .output_tokens = extractUint(resp,
            if (backend == .anthropic) "output_tokens" else "completion_tokens") orelse 0,
        .latency_ms    = latency_ms,
    };
}

// extractStr finds "field":"..." and returns a heap-allocated decoded string.
fn extractStr(ally: std.mem.Allocator, hay: []const u8, field: []const u8) ![]u8 {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "\"{s}\":\"", .{field}) catch return error.ParseError;
    const start = (std.mem.indexOf(u8, hay, key) orelse return error.ParseError) + key.len;

    // Two-pass: count decoded bytes, then fill buffer
    var si = start;
    var dlen: usize = 0;
    while (si < hay.len) {
        if (hay[si] == '"') break;
        if (hay[si] == '\\') { si += 2; } else { si += 1; }
        dlen += 1;
    }
    if (si >= hay.len or hay[si] != '"') return error.ParseError;

    const buf = try ally.alloc(u8, dlen);
    si = start;
    var oi: usize = 0;
    while (si < hay.len) {
        const c = hay[si];
        if (c == '"') break;
        if (c == '\\' and si + 1 < hay.len) {
            si += 1;
            buf[oi] = switch (hay[si]) {
                '"'  => '"',  '\\' => '\\',
                'n'  => '\n', 'r'  => '\r', 't' => '\t',
                else => hay[si],
            };
        } else {
            buf[oi] = c;
        }
        oi += 1;
        si += 1;
    }
    return buf[0..oi];
}

// extractObject finds "key": and returns a heap-allocated copy of the balanced
// JSON object that follows (used for Anthropic tool_use "input" field).
fn extractObject(ally: std.mem.Allocator, hay: []const u8, key: []const u8) ![]u8 {
    const kpos = std.mem.indexOf(u8, hay, key) orelse return error.ParseError;
    var i = kpos + key.len;
    while (i < hay.len and hay[i] == ' ') i += 1;
    if (i >= hay.len or hay[i] != '{') return error.ParseError;

    var depth: usize = 0;
    const start = i;
    while (i < hay.len) : (i += 1) switch (hay[i]) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return ally.dupe(u8, hay[start .. i + 1]);
        },
        '"' => {
            i += 1;
            while (i < hay.len) : (i += 1) {
                if (hay[i] == '\\') { i += 1; }
                else if (hay[i] == '"') break;
            }
        },
        else => {},
    };
    return error.ParseError;
}

fn extractUint(hay: []const u8, field: []const u8) ?u32 {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "\"{s}\":", .{field}) catch return null;
    const after = (std.mem.indexOf(u8, hay, key) orelse return null) + key.len;
    var i = after;
    while (i < hay.len and hay[i] == ' ') i += 1;
    const ns = i;
    while (i < hay.len and hay[i] >= '0' and hay[i] <= '9') i += 1;
    if (i == ns) return null;
    return std.fmt.parseInt(u32, hay[ns..i], 10) catch null;
}
