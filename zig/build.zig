const std = @import("std");

const generated_protocol_files = [_][]const u8{
    "src/generated/protocol_opcodes.zig",
    "src/generated/protocol_schema_test.zig",
    "src/generated/protocol_command_size.zig",
};

fn ensureGeneratedProtocolArtifacts(b: *std.Build) void {
    var missing: [generated_protocol_files.len][]const u8 = undefined;
    var missing_count: usize = 0;

    for (generated_protocol_files) |path| {
        if (b.build_root.handle.access(b.graph.io, path, .{})) |_| {} else |err| switch (err) {
            error.FileNotFound => {
                missing[missing_count] = path;
                missing_count += 1;
            },
            else => std.debug.panic("failed to check for generated Zig protocol artifacts at {s}: {s}", .{ path, @errorName(err) }),
        }
    }

    if (missing_count == 0) return;

    std.debug.print("error: missing generated Zig protocol artifacts.\nRun `mix protocol.gen` from the repository root, then rerun `zig build` in `zig/`.\nMissing files:\n", .{});
    for (missing[0..missing_count]) |path| {
        std.debug.print("  - {s}\n", .{path});
    }
    std.process.exit(1);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    ensureGeneratedProtocolArtifacts(b);

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
        .{ .name = "erlang", .has_scanner = true },
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
        .{ .name = "clojure", .has_scanner = false },
        .{ .name = "objc", .has_scanner = false },
        .{ .name = "sql", .has_scanner = true },
        .{ .name = "xml", .has_scanner = true },
        .{ .name = "ini", .has_scanner = false },
        .{ .name = "swift", .has_scanner = true },
        .{ .name = "vim", .has_scanner = true },
        .{ .name = "protobuf", .has_scanner = false },
        .{ .name = "fish", .has_scanner = true },
        .{ .name = "perl", .has_scanner = true },
    };

    var grammar_libs: [grammars.len]*std.Build.Step.Compile = undefined;
    for (grammars, 0..) |g, i| {
        grammar_libs[i] = addGrammar(b, target, c_optimize, g.name, g.has_scanner, g.scanner_extra_flags);
    }

    const test_step = b.step("test", "Run unit tests");

    // ── Parser executable (tree-sitter only) ──────────────────────────────
    // The Zig renderer (libvaxis/zigzag) was removed in #2223. This build now
    // produces parser infrastructure only: minga-parser, minga-hook-runner, and
    // the highlight benchmark.
    const parser_exe = b.addExecutable(.{
        .name = "minga-parser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parser_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    parser_exe.root_module.addIncludePath(b.path("vendor/tree-sitter/include"));
    parser_exe.root_module.link_libc = true;
    parser_exe.root_module.addCSourceFile(.{ .file = b.path("src/regex_sizeof.c"), .flags = &.{"-std=c11"} });
    parser_exe.root_module.linkLibrary(ts_lib);
    for (grammar_libs) |gl| parser_exe.root_module.linkLibrary(gl);
    b.installArtifact(parser_exe);

    // ── Hook runner executable (one-shot POSIX process-group helper) ─────
    const hook_runner_exe = b.addExecutable(.{
        .name = "minga-hook-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hook_runner_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hook_runner_exe.root_module.link_libc = true;
    b.installArtifact(hook_runner_exe);

    // Parser tests (highlighter, predicates, posix_regex)
    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parser_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    parser_tests.root_module.addIncludePath(b.path("vendor/tree-sitter/include"));
    parser_tests.root_module.link_libc = true;
    parser_tests.root_module.addCSourceFile(.{ .file = b.path("src/regex_sizeof.c"), .flags = &.{"-std=c11"} });
    parser_tests.root_module.linkLibrary(ts_lib);
    for (grammar_libs) |gl| parser_tests.root_module.linkLibrary(gl);

    const run_parser_tests = b.addRunArtifact(parser_tests);
    test_step.dependOn(&run_parser_tests.step);

    // ── Query/grammar compile guard ──────────────────────────────────────
    // Dedicated, explicitly-named step that compiles every shipped tree-sitter
    // query against its vendored grammar and fails on the first that does not
    // compile. This catches "silent drift": a grammar bump that renames or
    // removes a node makes `ts_query_new` return null at runtime, which only
    // logs a warning and yields no highlights. `zig build query-check` (and
    // CI) turn that into a hard failure. The same test also runs under
    // `zig build test`; this step lets CI surface it by name.
    const query_check_step = b.step("query-check", "Compile every shipped query against its grammar");
    const query_check_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parser_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &.{"query guard:"},
    });
    query_check_tests.root_module.addIncludePath(b.path("vendor/tree-sitter/include"));
    query_check_tests.root_module.link_libc = true;
    query_check_tests.root_module.addCSourceFile(.{ .file = b.path("src/regex_sizeof.c"), .flags = &.{"-std=c11"} });
    query_check_tests.root_module.linkLibrary(ts_lib);
    for (grammar_libs) |gl| query_check_tests.root_module.linkLibrary(gl);
    const run_query_check = b.addRunArtifact(query_check_tests);
    query_check_step.dependOn(&run_query_check.step);

    const hook_runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hook_runner_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hook_runner_tests.root_module.link_libc = true;

    const run_hook_runner_tests = b.addRunArtifact(hook_runner_tests);
    test_step.dependOn(&run_hook_runner_tests.step);

    // Tree-sitter highlight benchmark used by autoresearch.
    const highlight_bench = b.addExecutable(.{
        .name = "highlight-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/highlight_bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    highlight_bench.root_module.addIncludePath(b.path("vendor/tree-sitter/include"));
    highlight_bench.root_module.link_libc = true;
    highlight_bench.root_module.addCSourceFile(.{ .file = b.path("src/regex_sizeof.c"), .flags = &.{"-std=c11"} });
    highlight_bench.root_module.linkLibrary(ts_lib);
    for (grammar_libs) |gl| highlight_bench.root_module.linkLibrary(gl);

    const run_highlight_bench = b.addRunArtifact(highlight_bench);
    const highlight_bench_step = b.step("highlight-bench", "Run tree-sitter highlight benchmark");
    highlight_bench_step.dependOn(&run_highlight_bench.step);
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
