const std = @import("std");

pub const Import = std.Build.Module.Import;

/// Small helpers for the repeated example/benchmark target wiring in build.zig.
pub const Builder = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    examples_step: *std.Build.Step,

    pub fn executable(
        self: Builder,
        name: []const u8,
        root: []const u8,
        imports: []const Import,
    ) *std.Build.Step.Compile {
        return self.b.addExecutable(.{
            .name = name,
            .root_module = self.b.createModule(.{
                .root_source_file = self.b.path(root),
                .target = self.target,
                .optimize = self.optimize,
                .imports = imports,
            }),
        });
    }

    pub fn example(
        self: Builder,
        name: []const u8,
        root: []const u8,
        imports: []const Import,
    ) *std.Build.Step.Compile {
        const exe = self.executable(name, root, imports);
        const install = self.b.addInstallArtifact(exe, .{});
        self.b.getInstallStep().dependOn(&install.step);
        self.examples_step.dependOn(&install.step);
        return exe;
    }

    pub fn run(
        self: Builder,
        name: []const u8,
        description: []const u8,
        exe: *std.Build.Step.Compile,
    ) void {
        const run_artifact = self.b.addRunArtifact(exe);
        const step = self.b.step(name, description);
        step.dependOn(&run_artifact.step);
    }

    pub fn bench(
        self: Builder,
        step_name: []const u8,
        exe_name: []const u8,
        root: []const u8,
        description: []const u8,
        imports: []const Import,
    ) void {
        const exe = self.executable(exe_name, root, imports);
        self.run(step_name, description, exe);
    }

    pub fn buildBench(
        self: Builder,
        step_name: []const u8,
        exe_name: []const u8,
        root: []const u8,
        description: []const u8,
        imports: []const Import,
    ) void {
        const exe = self.executable(exe_name, root, imports);
        const install = self.b.addInstallArtifact(exe, .{});
        const step = self.b.step(step_name, description);
        step.dependOn(&install.step);
    }
};
