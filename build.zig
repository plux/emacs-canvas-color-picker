const std = @import("std");

var io: std.Io.Threaded = .init_single_threaded;

fn hasEmacsHeader(b: *std.Build, dir: []const u8) bool {
    const path = b.pathJoin(&.{ dir, "emacs-module.h" });
    std.Io.Dir.cwd().access(io.io(), path, .{}) catch return false;
    return true;
}

fn emacsIncludeDir(b: *std.Build) []const u8 {
    if (b.option([]const u8, "emacs-include-dir", "Directory containing emacs-module.h")) |dir| {
        if (hasEmacsHeader(b, dir)) return dir;
        std.debug.panic("EMACS_INCLUDE_DIR={s} does not contain emacs-module.h", .{dir});
    }
    @panic("Set EMACS_INCLUDE_DIR (or pass -Demacs-include-dir)");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const include_dir = emacsIncludeDir(b);
    const emacs_module = b.addTranslateC(.{
        .root_source_file = b.path("src/emacs_module_import.h"),
        .target = target,
        .optimize = optimize,
    });
    emacs_module.addIncludePath(.{ .cwd_relative = include_dir });

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
