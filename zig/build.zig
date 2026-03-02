const std = @import("std");

const BackendOption = enum {
    tui,
    gui,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backend = b.option(BackendOption, "backend", "Rendering backend (default: tui)") orelse .tui;

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    // Build options module — passes compile-time config to Zig source.
    const build_options = b.addOptions();
    build_options.addOption(BackendOption, "backend", backend);

    // ── Tree-sitter static library ────────────────────────────────────────
    const ts_lib = b.addLibrary(.{
        .name = "tree-sitter",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    ts_lib.root_module.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/src/lib.c"),
        .flags = &.{"-std=c11"},
    });
    ts_lib.root_module.addIncludePath(b.path("vendor/tree-sitter/src"));
    ts_lib.root_module.addIncludePath(b.path("vendor/tree-sitter/include"));
    ts_lib.root_module.link_libc = true;

    // Main executable
    const exe = b.addExecutable(.{
        .name = "minga-renderer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("vaxis", vaxis.module("vaxis"));
    exe.root_module.addImport("build_options", build_options.createModule());
    exe.root_module.addIncludePath(b.path("vendor/tree-sitter/include"));
    exe.linkLibrary(ts_lib);

    // GUI backend: compile Swift, link AppKit/Foundation frameworks.
    if (backend == .gui) {
        addGuiBuildSteps(b, exe);
    }

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the renderer");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("vaxis", vaxis.module("vaxis"));
    tests.root_module.addImport("build_options", build_options.createModule());
    tests.root_module.addIncludePath(b.path("vendor/tree-sitter/include"));
    tests.linkLibrary(ts_lib);

    if (backend == .gui) {
        addGuiBuildSteps(b, tests);
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Configure GUI-specific build steps: compile Swift → .o, link frameworks,
/// add C include paths.
fn addGuiBuildSteps(b: *std.Build, compile: *std.Build.Step.Compile) void {
    // Compile Swift source to object file.
    const swift_compile = b.addSystemCommand(&.{
        "swiftc",
        "-c",
        "-parse-as-library",
        "-emit-object",
        "-o",
    });
    const swift_obj = swift_compile.addOutputFileArg("MingaApp.o");
    swift_compile.addFileArg(b.path("swift/MingaApp.swift"));
    swift_compile.addArgs(&.{
        "-import-objc-header",
    });
    swift_compile.addFileArg(b.path("swift/include/minga_gui.h"));

    // Link the Swift object file.
    compile.root_module.addObjectFile(swift_obj);

    // Add the bridging header include path so Zig can @cImport("minga_gui.h").
    compile.root_module.addIncludePath(b.path("swift/include"));

    // Link macOS frameworks.
    compile.root_module.linkFramework("AppKit", .{});
    compile.root_module.linkFramework("Foundation", .{});
    compile.root_module.linkFramework("CoreText", .{});
    compile.root_module.linkFramework("CoreGraphics", .{});
    compile.root_module.linkFramework("CoreFoundation", .{});
    compile.root_module.linkFramework("Metal", .{});

    compile.root_module.linkFramework("QuartzCore", .{});

    // Metal shaders are compiled at runtime from source embedded in Swift.
    // See MingaApp.swift setupMetal() for the compilation path.
    // The shader source file (src/font/shaders.metal) is read by Zig at
    // comptime and passed to Swift via a C-ABI function.

    // Link the Swift runtime and overlay libraries. On macOS, these live
    // in the SDK's /usr/lib/swift/ directory as .tbd stubs (the actual
    // dylibs are in the shared cache). Importing AppKit from Swift
    // transitively pulls in all these overlay libraries.
    compile.root_module.addLibraryPath(.{
        .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/swift",
    });
    const swift_libs = [_][]const u8{
        "swiftCore",
        "swiftObjectiveC",
        "swiftCoreFoundation",
        "swiftCoreImage",
        "swiftDispatch",
        "swiftIOKit",
        "swiftMetal",

        "swiftOSLog",
        "swiftQuartzCore",
        "swiftUniformTypeIdentifiers",
        "swiftXPC",
        "swift_Builtin_float",
        "swiftos",
        "swiftsimd",
    };
    for (swift_libs) |lib| {
        compile.root_module.linkSystemLibrary(lib, .{});
    }
}
