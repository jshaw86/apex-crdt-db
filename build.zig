const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Database executable
    const exe = b.addExecutable(.{
        .name = "database",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Run database step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the database server");
    run_step.dependOn(&run_cmd.step);

    const protocol_module = b.createModule(.{
        .root_source_file = b.path("src/protocol/frame.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Helper for compiling tests
    const tests = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "mutation_test", .path = "tests/mutation_test.zig" },
        .{ .name = "query_test", .path = "tests/query_test.zig" },
        .{ .name = "dynamic_schema_test", .path = "tests/dynamic_schema_test.zig" },
        .{ .name = "schema_test", .path = "tests/schema_test.zig" },
        .{ .name = "aw_set_test", .path = "tests/aw_set_test.zig" },
        .{ .name = "replication_test_client", .path = "tests/replication_test_client.zig" },
        .{ .name = "crdt_race_test", .path = "tests/crdt_race_test.zig" },
    };

    inline for (tests) |t| {
        const test_exe = b.addExecutable(.{
            .name = t.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(t.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_exe.root_module.addImport("protocol", protocol_module);
        b.installArtifact(test_exe);

        const run_test_cmd = b.addRunArtifact(test_exe);
        run_test_cmd.step.dependOn(b.getInstallStep());
        const run_test_step = b.step(b.fmt("run-{s}", .{t.name}), b.fmt("Run test {s}", .{t.name}));
        run_test_step.dependOn(&run_test_cmd.step);
    }

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/storage/engine.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
