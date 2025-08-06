const std = @import("std");

pub fn build(b: *std.Build) void {
    const pulse_mod = b.addModule("pulse", .{
        .root_source_file = b.path("src/pulse.zig"),
    });

    const test_step = b.step("test", "");

    {
        const test_exe = b.addExecutable(.{
            .name = "pulsetest",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/pulsetest.zig"),
                .imports = &.{
                    .{ .name = "pulse", .module = pulse_mod },
                },
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        const install = b.addInstallArtifact(test_exe, .{});
        b.step("install-pulsetest", "").dependOn(&install.step);
        const run = b.addRunArtifact(test_exe);
        run.step.dependOn(&install.step);
        test_step.dependOn(&run.step);
    }
}
