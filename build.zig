const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const emacs_source_dir = b.option([]const u8, "emacs-source-dir", "Path to the Emacs source tree") orelse
        @panic("Pass -Demacs-source-dir=/path/to/emacs-source");
    const emacs_module = b.addTranslateC(.{
        .root_source_file = b.path("src/emacs_module_import.h"),
        .target = target,
        .optimize = optimize,
    });
    emacs_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ emacs_source_dir, "src" }) });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/module.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("emacs_module", emacs_module.createModule());

    const lib = b.addLibrary(.{
        .name = "color-picker",
        .linkage = .dynamic,
        .root_module = root_module,
    });
    b.installArtifact(lib);
}
