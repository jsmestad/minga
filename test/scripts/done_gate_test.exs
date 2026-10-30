# This module launches shell commands and Git in isolated temporary repositories.
defmodule Minga.DoneGateTest do
  use ExUnit.Case, async: false

  @moduletag :heavy
  @moduletag timeout: 30_000
  @root Path.expand("../..", __DIR__)
  @git_env [
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_AUTHOR_NAME", "Gate Test"},
    {"GIT_AUTHOR_EMAIL", "gate@example.com"},
    {"GIT_COMMITTER_NAME", "Gate Test"},
    {"GIT_COMMITTER_EMAIL", "gate@example.com"},
    {"CREDO_CHANGED_BASE_REF", "main"}
  ]

  setup do
    dir = Path.join(System.tmp_dir!(), "minga-done-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "scripts/lib"))
    {canonical_dir, 0} = System.cmd("pwd", ["-P"], cd: dir)
    dir = String.trim(canonical_dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for path <- ["scripts/lint", "scripts/credo_changed", "scripts/lib/changed_files.sh"] do
      File.cp!(Path.join(@root, path), Path.join(dir, path))
    end

    File.cp!(Path.join(@root, ".tool-versions"), Path.join(dir, ".tool-versions"))
    git!(dir, ["init", "-b", "main"])
    git!(dir, ["config", "core.hooksPath", "/dev/null"])
    write!(dir, ".gitignore", "bin/\nresults/\n")
    write!(dir, "lib/deleted.ex", "baseline\n")
    write!(dir, "macos/source.swift", "baseline\n")
    write!(dir, "docs/protocol_schema.toml", "baseline\n")
    commit!(dir)
    git!(dir, ["checkout", "-b", "feature"])

    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    for command <- ~w(bash git awk tr mktemp date cat rm mkdir grep jq) do
      File.ln_s!(System.find_executable(command), Path.join(bin, command))
    end

    executable!(dir, "elixir", "printf '%s\\n' '#{System.version()}'")

    executable!(dir, "mix", """
    case "$1" in
      compile) exit "${COMPILE_EXIT:-0}" ;;
      test.llm) echo 'ExUnit failure detail'; exit "${TEST_EXIT:-0}" ;;
      swift.build) echo 'NOISY BUILD OUTPUT'; exit "${BUILD_EXIT:-0}" ;;
    esac
    """)

    {:ok, dir: dir, env: [{"PATH", bin}]}
  end

  test "both change formats include all four sources and preserve unusual paths", %{dir: dir} do
    write!(dir, "lib/branch.ex", "branch\n")
    commit!(dir)
    git!(dir, ["checkout", "main"])
    write!(dir, "base-only.txt", "not a feature change\n")
    commit!(dir)
    git!(dir, ["checkout", "feature"])
    File.rm!(Path.join(dir, "lib/deleted.ex"))
    git!(dir, ["add", "-u"])
    write!(dir, ".tool-versions", "unstaged\n")
    write!(dir, "macos/naïve name.swift", "untracked\n")
    write!(dir, "lib/line\nbreak.ex", "untracked\n")

    {nul, 0} = shell(dir, "source scripts/lib/changed_files.sh; changed_files_z")
    {lines, 0} = shell(dir, "source scripts/lib/changed_files.sh; changed_files")

    assert MapSet.new(String.split(nul, <<0>>, trim: true)) ==
             MapSet.new([
               "lib/branch.ex",
               "lib/deleted.ex",
               ".tool-versions",
               "macos/naïve name.swift",
               "lib/line\nbreak.ex"
             ])

    assert lines == String.replace(nul, <<0>>, "\n")

    assert {"", 0} =
             shell(dir, """
             source scripts/lib/changed_files.sh
             paths=$(changed_files)
             elixir_changed "$paths" && macos_changed "$paths"
             """)

    assert {"", 0} =
             shell(dir, """
             source scripts/lib/changed_files.sh
             paths=$(changed_files)
             ! macos_changed 'macos-not-relevant.swift' &&
               elixir_changed 'docs/protocol_schema.toml' &&
               macos_changed 'docs/protocol_schema.toml'
             """)
  end

  test "base override works and an invalid base fails instead of omitting changes", %{dir: dir} do
    write!(dir, "lib/branch.ex", "branch\n")
    commit!(dir)

    assert {"", 0} =
             shell(dir, "source scripts/lib/changed_files.sh; changed_files", [
               {"CREDO_CHANGED_BASE_REF", "HEAD"}
             ])

    for command <- [
          "source scripts/lib/changed_files.sh; changed_files",
          "scripts/credo_changed",
          "scripts/lint done"
        ] do
      {output, status} = shell(dir, command, [{"CREDO_CHANGED_BASE_REF", "missing-base"}])
      assert status != 0
      assert output =~ "Could not determine changed files against missing-base"
    end
  end

  test "renames out of macOS inputs retain both old and new paths", %{dir: dir} do
    for {source, destination} <- [
          {"macos/source.swift", "moved.swift"},
          {"docs/protocol_schema.toml", "schema.toml"}
        ] do
      git!(dir, ["mv", source, destination])

      for base <- ["HEAD", "HEAD~1"] do
        if base == "HEAD~1", do: commit!(dir)

        {paths, 0} =
          shell(dir, "source scripts/lib/changed_files.sh; changed_files_z", [
            {"CREDO_CHANGED_BASE_REF", base}
          ])

        assert MapSet.new(String.split(paths, <<0>>, trim: true)) ==
                 MapSet.new([source, destination])
      end
    end
  end

  test "full lint does not need a comparison base", ctx do
    {output, 0} =
      shell(ctx.dir, "scripts/lint full", [
        {"CREDO_CHANGED_BASE_REF", "missing-base"} | ctx.env
      ])

    assert output =~ "[pass] compile"
    assert output =~ "[pass] dialyzer"
    assert output =~ "[pass] reach"
    refute output =~ "Could not determine changed files"
  end

  test "gate preserves failures while running independent stages and explicitly skipping Swift",
       ctx do
    write!(ctx.dir, "lib/change.ex", "changed\n")
    {output, 1} = gate(ctx, [{"COMPILE_EXIT", "1"}, {"TEST_EXIT", "1"}])

    assert output =~ "[FAIL] compile"
    assert output =~ "[FAIL] test.llm"
    assert output =~ "ExUnit failure detail"
    assert output =~ "[skip] dialyzer"
    assert output =~ "compile failed"
    assert output =~ "[skip] swift.build"
    assert output =~ "[skip] swift.test"
    assert output =~ "no macOS-relevant file changed"
    refute output =~ "All local review checks passed"
  end

  test "macOS changes explicitly skip both Swift stages without xcodebuild", ctx do
    write!(ctx.dir, "macos/project.yml", "changed\n")
    {output, 0} = gate(ctx)
    assert output =~ "[skip] swift.build"
    assert output =~ "[skip] swift.test"
    assert length(Regex.scan(~r/xcodebuild not found/, output)) == 2
  end

  test "protocol schema changes run both Swift stages", ctx do
    install_swift!(ctx.dir)
    write!(ctx.dir, "docs/protocol_schema.toml", "changed\n")
    {output, 0} = gate(ctx)
    assert output =~ "[pass] swift.build"
    assert output =~ "[pass] swift.test"
  end

  test "Swift test failures retain results and report qualified names without raw build output",
       ctx do
    install_swift!(ctx.dir)
    write!(ctx.dir, "macos/project.yml", "changed\n")
    {output, 1} = gate(ctx, [{"SWIFT_EXIT", "65"}])

    assert output =~ "[pass] swift.build"
    assert output =~ "[FAIL] swift.test"
    assert output =~ "xcresult: #{ctx.dir}/results/swift.xcresult"
    assert output =~ "RenderingTests/testCaret()"
    refute output =~ "testPassing"
    refute output =~ "NOISY"
    assert File.dir?(Path.join(ctx.dir, "results/swift.xcresult"))
    assert File.read!(Path.join(ctx.dir, "results/swift-test.log")) =~ "NOISY TEST OUTPUT"
    assert File.read!(Path.join(ctx.dir, "results/swift-build.log")) =~ "NOISY BUILD OUTPUT"
  end

  test "Swift build failure skips tests and keeps a diagnostic log", ctx do
    install_swift!(ctx.dir)
    write!(ctx.dir, "macos/project.yml", "changed\n")
    {output, 1} = gate(ctx, [{"BUILD_EXIT", "65"}])

    assert output =~ "[FAIL] swift.build"
    assert output =~ "[skip] swift.test"
    assert output =~ "swift.build failed"
    assert output =~ "Build log: #{ctx.dir}/results/swift-build.log"
    refute output =~ "NOISY"
    refute File.exists?(Path.join(ctx.dir, "results/swift-test.log"))
  end

  test "artifact setup failure preserves earlier stage failures", ctx do
    install_swift!(ctx.dir)
    write!(ctx.dir, "macos/project.yml", "changed\n")

    {output, status} =
      gate(ctx, [
        {"MINGA_DONE_DIR", Path.join(ctx.dir, ".tool-versions")},
        {"TEST_EXIT", "1"}
      ])

    assert status != 0
    assert output =~ "[FAIL] test.llm"
    assert output =~ "ExUnit failure detail"
    assert output =~ "[FAIL] swift.build"
    assert output =~ "[skip] swift.test"
  end

  test "a failed Swift launch without results names the retained log", ctx do
    install_swift!(ctx.dir)
    write!(ctx.dir, "macos/project.yml", "changed\n")
    {output, 1} = gate(ctx, [{"SWIFT_EXIT", "65"}, {"NO_RESULT", "1"}])
    assert output =~ "No xcresult bundle was produced"
    assert output =~ "Test log: #{ctx.dir}/results/swift-test.log"
    refute output =~ "NOISY"
  end

  defp install_swift!(dir) do
    executable!(dir, "xcodebuild", """
    echo 'NOISY TEST OUTPUT'
    if [ "${NO_RESULT:-0}" = 0 ]; then mkdir -p "${@: -1}"; fi
    exit "${SWIFT_EXIT:-0}"
    """)

    executable!(dir, "xcrun", """
    cat <<'JSON'
    {"testNodes":[{"nodeType":"Test Suite","result":"Failed","children":[
      {"nodeType":"Test Case","result":"Failed","name":"testCaret()","nodeIdentifier":"RenderingTests/testCaret()"},
      {"nodeType":"Test Case","result":"Passed","nodeIdentifier":"RenderingTests/testPassing()"}
    ]}]}
    JSON
    """)
  end

  defp gate(ctx, extra_env \\ []) do
    shell(ctx.dir, "scripts/lint done", [
      {"MINGA_DONE_DIR", Path.join(ctx.dir, "results")} | extra_env ++ ctx.env
    ])
  end

  defp shell(dir, command, env \\ []) do
    System.cmd("bash", ["-o", "pipefail", "-c", command],
      cd: dir,
      env: Map.to_list(Map.merge(Map.new(@git_env), Map.new(env))),
      stderr_to_stdout: true
    )
  end

  defp executable!(dir, name, body) do
    path = Path.join([dir, "bin", name])
    File.write!(path, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod!(path, 0o755)
  end

  defp write!(dir, path, content) do
    path = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp commit!(dir) do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--allow-empty", "-m", "fixture"])
  end

  defp git!(dir, args) do
    {output, status} = System.cmd("git", args, cd: dir, env: @git_env, stderr_to_stdout: true)
    assert status == 0, output
  end
end
