const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "icarium", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run icarium");
    run_step.dependOn(&run_cmd.step);

    const core = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("icarium", core);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const e2e = b.addSystemCommand(&.{ "sh", "tests/e2e/run.sh" });
    e2e.step.dependOn(b.getInstallStep());
    b.step("e2e", "Run SystemVerilog end-to-end suite (needs yosys)").dependOn(&e2e.step);

    const fixtures = b.addSystemCommand(&.{ "sh", "fixtures/run.sh" });
    fixtures.step.dependOn(b.getInstallStep());
    b.step("fixtures", "Run rule fixtures against manifests (needs yosys)").dependOn(&fixtures.step);

    const schemas = b.addSystemCommand(&.{ "sh", "scripts/validate-schemas.sh" });
    schemas.step.dependOn(b.getInstallStep());
    b.step("schemas", "Validate emitted JSON against schema/ (needs yosys, jsonschema)").dependOn(&schemas.step);

    const suppress = b.addSystemCommand(&.{ "sh", "tests/suppress/run.sh" });
    suppress.step.dependOn(b.getInstallStep());
    b.step("suppress", "Run suppression CLI suite (needs yosys, jsonschema)").dependOn(&suppress.step);

    const bench = b.addSystemCommand(&.{ "python3", "bench/bench.py" });
    bench.step.dependOn(b.getInstallStep());
    b.step("bench", "Head-to-head vs rtl-buddy-cdc tiers 1-2 (needs yosys, fusesoc for tier 2)").dependOn(&bench.step);

    const oracle = b.addSystemCommand(&.{ "python3", "bench/oracle.py" });
    oracle.step.dependOn(b.getInstallStep());
    const recall = b.addSystemCommand(&.{ "python3", "bench/recall.py" });
    recall.step.dependOn(&oracle.step);
    b.step("recall", "Waiver-oracle recall over tier-2 blocks (needs yosys, fusesoc)").dependOn(&recall.step);

    if (b.option([]const u8, "test-file", "Run one test file, e.g. tests/ir_path_test.zig")) |file| {
        const one_mod = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        });
        one_mod.addImport("icarium", core);
        const one_tests = b.addTest(.{ .root_module = one_mod });
        const run_one = b.addRunArtifact(one_tests);
        const one_step = b.step("test-file", "Run one test file");
        one_step.dependOn(&run_one.step);
    }
}
