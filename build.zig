const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const evmc_include_path = "third-party/evmc/v11.0.1";

    const evm_module = b.createModule(.{
        .root_source_file = .{ .path = "src/evm/opcodes.zig" },
    });
    evm_module.addIncludePath(.{ .path = evmc_include_path });

    const exe = b.addExecutable(.{
        .name = "zenith",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addIncludePath(.{ .path = evmc_include_path });
    b.installArtifact(exe);

    const mnemonic_exe = b.addExecutable(.{
        .name = "mnc",
        .root_source_file = .{ .path = "src/mnemonic-compiler/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    mnemonic_exe.root_module.addImport("evm", evm_module);
    mnemonic_exe.addIncludePath(.{ .path = evmc_include_path });
    b.installArtifact(mnemonic_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    unit_tests.addIncludePath(.{ .path = evmc_include_path });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const mnc_unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/mnemonic-compiler/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    mnc_unit_tests.root_module.addImport("evm", evm_module);
    mnc_unit_tests.addIncludePath(.{ .path = evmc_include_path });

    const run_mnc_unit_tests = b.addRunArtifact(mnc_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_mnc_unit_tests.step);
}
