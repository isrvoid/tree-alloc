const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const trpc = b.addStaticLibrary(.{
        .name = "tree_alloc",
        .target = target,
        .optimize = optimize,
    });
    trpc.addCSourceFile("src/tree_allocator.c", &.{});
    trpc.addIncludePath("src");
    trpc.linkLibC();

    const exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = .{ .path = "src/benchmark.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(trpc);
    exe.addIncludePath("src");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/test.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe_tests.linkLibrary(trpc);
    exe_tests.addIncludePath("src");
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
