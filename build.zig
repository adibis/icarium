const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const onnxruntime_inc = b.option([]const u8, "onnxruntime-include", "OnnxRuntime include dir") orelse
        "/opt/homebrew/include/onnxruntime";
    const onnxruntime_lib = b.option([]const u8, "onnxruntime-lib", "OnnxRuntime lib dir") orelse
        "/opt/homebrew/lib";

    const pq_inc = b.option([]const u8, "pq-include", "libpq include dir") orelse
        "/opt/homebrew/opt/postgresql@16/include";
    const pq_lib = b.option([]const u8, "pq-lib", "libpq lib dir") orelse
        "/opt/homebrew/opt/postgresql@16/lib";

    // --- C inference + db layer (libicarium_infer, static) ---
    const infer_mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    infer_mod.addCSourceFiles(.{
        .files = &.{
            "src/c/infer.c",
            "src/c/tok.c",
            "src/c/db.c",
        },
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-lm" },
    });
    infer_mod.addIncludePath(.{ .cwd_relative = onnxruntime_inc });
    infer_mod.addIncludePath(.{ .cwd_relative = pq_inc });
    infer_mod.addIncludePath(.{ .cwd_relative = "src/c" });
    infer_mod.addLibraryPath(.{ .cwd_relative = pq_lib });
    infer_mod.linkSystemLibrary("pq", .{});

    const infer_lib = b.addLibrary(.{
        .name = "icarium_infer",
        .root_module = infer_mod,
        .linkage = .static,
    });
    b.installArtifact(infer_lib);

    // --- icariumd: daemon (Zig, links C layer) ---
    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    daemon_mod.addIncludePath(.{ .cwd_relative = onnxruntime_inc });
    daemon_mod.addIncludePath(.{ .cwd_relative = pq_inc });
    daemon_mod.addIncludePath(.{ .cwd_relative = "src/c" });
    daemon_mod.addLibraryPath(.{ .cwd_relative = onnxruntime_lib });
    daemon_mod.addLibraryPath(.{ .cwd_relative = pq_lib });
    daemon_mod.linkSystemLibrary("onnxruntime", .{});
    daemon_mod.linkSystemLibrary("pq", .{});
    daemon_mod.linkLibrary(infer_lib);

    const daemon = b.addExecutable(.{
        .name = "icariumd",
        .root_module = daemon_mod,
    });
    b.installArtifact(daemon);

    // --- icarium: CLI client ---
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/zig/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const cli = b.addExecutable(.{
        .name = "icarium",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    // --- test_infer: C smoke test ---
    const test_mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addCSourceFiles(.{
        .files = &.{"tests/test_infer.c"},
        .flags = &.{ "-std=c11", "-Wall" },
    });
    test_mod.addIncludePath(.{ .cwd_relative = onnxruntime_inc });
    test_mod.addIncludePath(.{ .cwd_relative = "src/c" });
    test_mod.addLibraryPath(.{ .cwd_relative = onnxruntime_lib });
    test_mod.linkSystemLibrary("onnxruntime", .{});
    test_mod.linkLibrary(infer_lib);

    const test_infer = b.addExecutable(.{
        .name = "test_infer",
        .root_module = test_mod,
    });

    const run_test = b.addRunArtifact(test_infer);
    run_test.setCwd(b.path("."));  // so MODELS_DIR = "models/" resolves correctly

    const test_step = b.step("test", "Run C smoke tests");
    test_step.dependOn(&run_test.step);
}
