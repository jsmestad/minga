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
    // Always optimize vendored C code — query compilation is 100x slower
    // in debug mode, and we never debug third-party C libraries.
    const c_optimize: std.builtin.OptimizeMode = .ReleaseFast;

    const ts_lib = b.addLibrary(.{
        .name = "tree-sitter",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = c_optimize,
        }),
    });
    ts_lib.root_module.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/src/lib.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    ts_lib.root_module.addIncludePath(b.path("vendor/tree-sitter/src"));
    ts_lib.root_module.addIncludePath(b.path("vendor/tree-sitter/include"));
    ts_lib.root_module.link_libc = true;

    // ── Grammar static libraries ───────────────────────────────────────
    const Grammar = struct {
        name: []const u8,
        has_scanner: bool,
        /// Extra C flags for the scanner (e.g. to suppress UB in vendored code).
        scanner_extra_flags: []const []const u8 = &.{},
    };
    const grammars = [_]Grammar{
        .{ .name = "elixir", .has_scanner = true },
        .{ .name = "heex", .has_scanner = false },
        .{ .name = "json", .has_scanner = false },
        // YAML scanner casts char* to int16_t* without alignment guarantees.
        .{ .name = "yaml", .has_scanner = true, .scanner_extra_flags = &.{"-fno-sanitize=undefined"} },
        .{ .name = "toml", .has_scanner = true },
        .{ .name = "markdown", .has_scanner = true },
        .{ .name = "markdown_inline", .has_scanner = true },
        .{ .name = "ruby", .has_scanner = true },
        .{ .name = "javascript", .has_scanner = true },
        .{ .name = "typescript", .has_scanner = true },
        .{ .name = "tsx", .has_scanner = true },
        .{ .name = "go", .has_scanner = false },
        .{ .name = "rust", .has_scanner = true },
        .{ .name = "zig", .has_scanner = false },
        .{ .name = "erlang", .has_scanner = false },
        .{ .name = "bash", .has_scanner = true },
        .{ .name = "c", .has_scanner = false },
        .{ .name = "cpp", .has_scanner = true },
        .{ .name = "html", .has_scanner = true },
        .{ .name = "css", .has_scanner = true },
        .{ .name = "lua", .has_scanner = true },
        .{ .name = "python", .has_scanner = true },
        .{ .name = "kotlin", .has_scanner = true },
        .{ .name = "gleam", .has_scanner = true },
        .{ .name = "java", .has_scanner = false },
        .{ .name = "c_sharp", .has_scanner = true },
        .{ .name = "php", .has_scanner = true },
        .{ .name = "dockerfile", .has_scanner = true },
        .{ .name = "hcl", .has_scanner = true },
        .{ .name = "scss", .has_scanner = true },
        .{ .name = "graphql", .has_scanner = false },
        .{ .name = "nix", .has_scanner = true },
        .{ .name = "ocaml", .has_scanner = true },
        .{ .name = "haskell", .has_scanner = true },
        .{ .name = "scala", .has_scanner = true },
        .{ .name = "r", .has_scanner = true },
        .{ .name = "dart", .has_scanner = true },
        .{ .name = "make", .has_scanner = false },
        .{ .name = "diff", .has_scanner = false },
        .{ .name = "elisp", .has_scanner = false },

    };

    var grammar_libs: [grammars.len]*std.Build.Step.Compile = undefined;
    for (grammars, 0..) |g, i| {
        grammar_libs[i] = addGrammar(b, target, c_optimize, g.name, g.has_scanner, g.scanner_extra_flags);
    }

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
    // Note: tree-sitter and grammars are linked only to minga-parser, not the renderer.

    // GUI backend: compile Swift, link AppKit/Foundation frameworks.
    if (backend == .gui) {
        addGuiBuildSteps(b, exe);
    }

    b.installArtifact(exe);

    // ── Parser executable (tree-sitter only, no renderer/libvaxis) ────────
    const parser_exe = b.addExecutable(.{
        .name = "minga-parser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parser_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    parser_exe.root_module.addIncludePath(b.path("vendor/tree-sitter/include"));
    parser_exe.linkLibrary(ts_lib);
    for (grammar_libs) |gl| parser_exe.linkLibrary(gl);
    b.installArtifact(parser_exe);

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

    if (backend == .gui) {
        addGuiBuildSteps(b, tests);
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Build a static library for a tree-sitter grammar.
/// Each grammar has `src/parser.c` and optionally `src/scanner.c`.
fn addGrammar(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    has_scanner: bool,
    scanner_extra_flags: []const []const u8,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = b.fmt("ts-grammar-{s}", .{name}),
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.root_module.link_libc = true;

    const grammar_dir = b.fmt("vendor/grammars/{s}/src", .{name});
    lib.root_module.addIncludePath(b.path(grammar_dir));
    lib.root_module.addIncludePath(b.path("vendor/tree-sitter/include"));

    // parser.c
    lib.root_module.addCSourceFile(.{
        .file = b.path(b.fmt("vendor/grammars/{s}/src/parser.c", .{name})),
        .flags = &.{"-std=c11"},
    });

    // scanner.c (optional)
    if (has_scanner) {
        // Build flags: always -std=c11, plus any grammar-specific extras
        var flag_buf: [8][]const u8 = undefined;
        flag_buf[0] = "-std=c11";
        var flag_count: usize = 1;
        for (scanner_extra_flags) |f| {
            flag_buf[flag_count] = f;
            flag_count += 1;
        }

        lib.root_module.addCSourceFile(.{
            .file = b.path(b.fmt("vendor/grammars/{s}/src/scanner.c", .{name})),
            .flags = flag_buf[0..flag_count],
        });
    }

    return lib;
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
