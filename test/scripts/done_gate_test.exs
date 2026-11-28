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

    for path <- [
          "scripts/lint",
          "scripts/credo_changed",
          "scripts/test_macos_unit",
          "scripts/lib/changed_files.sh"
        ] do
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

    {python, 0} = System.cmd("python3", ["-c", "import sys; print(sys.executable)"])
    File.ln_s!(String.trim(python), Path.join(bin, "python3"))

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
    evidence = native_results(ctx.dir)
    ordinary = hd(evidence["actions"])
    bundle = Path.join([ctx.dir, "results/native-unit", ordinary["result_bundle"]])
    log = Path.join([ctx.dir, "results/native-unit", ordinary["log"]])
    assert output =~ "xcresult: #{bundle}"
    assert output =~ "RenderingTests/testCaret()"
    refute output =~ "testPassing"
    refute output =~ "NOISY"
    assert File.dir?(bundle)
    assert File.read!(log) =~ "NOISY TEST OUTPUT"
    refute evidence["success"]
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
    refute File.exists?(Path.join(ctx.dir, "results/native-unit/results.json"))
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
    evidence = native_results(ctx.dir)
    ordinary = hd(evidence["actions"])
    assert output =~ "Test log: #{Path.join([ctx.dir, "results/native-unit", ordinary["log"]])}"
    refute output =~ "NOISY"
  end

  test "a failed hosted build leaves both focused runners unexecuted", ctx do
    install_swift!(ctx.dir)
    write!(ctx.dir, "macos/project.yml", "changed\n")
    {_output, 1} = gate(ctx, [{"HOSTED_BUILD_EXIT", "65"}])
    evidence = native_results(ctx.dir)
    [ordinary, policy, replay, geometry] = evidence["actions"]
    assert ordinary["success"]
    assert geometry["success"]
    assert policy["execution_identity"]["build"]["exit_code"] == 65

    for action <- [policy, replay] do
      refute action["success"]
      refute action["executed"]
      assert action["exit_code"] == 125
      assert action["summary"] == nil
      assert action["tests"] == nil
    end

    refute evidence["success"]
  end

  test "geometry leaves the hosted test bundle available for subsequent replay", ctx do
    install_swift!(ctx.dir)
    write!(ctx.dir, "macos/project.yml", "changed\n")
    {_output, 0} = gate(ctx)

    bundle =
      Path.join(
        ctx.dir,
        "macos/DerivedData/Build/Products/Debug/MingaTestHost.app/Contents/PlugIns/MingaTests.xctest"
      )

    assert File.dir?(bundle)
    assert native_results(ctx.dir)["success"]
  end

  test "site-only changes skip Elixir and Swift gates and run site checks", ctx do
    install_site!(ctx.dir)
    write!(ctx.dir, "site/index.html", "<html></html>\n")
    write!(ctx.dir, "wrangler.jsonc", "{\"name\":\"mingacode-site\"}\n")
    {output, 0} = gate(ctx)

    assert output =~ "[skip] format"
    assert output =~ "[skip] credo"
    assert output =~ "[skip] ex-dna"
    assert output =~ "[skip] compile"
    assert output =~ "[skip] dialyzer"
    assert output =~ "[skip] reach"
    assert output =~ "[skip] test.llm"
    assert output =~ "site-only changes"
    assert output =~ "[pass] site.test"
    assert output =~ "[pass] site"
    assert output =~ "[skip] swift.build"
    assert output =~ "[skip] swift.test"
  end

  test "site check failures fail the gate on site-only changes", ctx do
    install_site!(ctx.dir)
    write!(ctx.dir, "site/index.html", "<html></html>\n")
    {output, 1} = gate(ctx, [{"SITE_CHECK_EXIT", "1"}])

    assert output =~ "[skip] test.llm"
    assert output =~ "[FAIL] site"
    assert output =~ "broken site link"
    refute output =~ "All local review checks passed"
  end

  test "mixed site and Elixir changes run both Elixir and site gates", ctx do
    install_site!(ctx.dir)
    write!(ctx.dir, "site/index.html", "<html></html>\n")
    write!(ctx.dir, "lib/change.ex", "changed\n")
    {output, 0} = gate(ctx)

    assert output =~ "[pass] format"
    assert output =~ "[pass] compile"
    assert output =~ "[pass] test.llm"
    assert output =~ "[pass] site.test"
    assert output =~ "[pass] site"
  end

  defp install_site!(dir) do
    write!(dir, "test/scripts/check_site_links_test.py", """
    import unittest

    class StubSiteLinksTest(unittest.TestCase):
        def test_ok(self):
            self.assertTrue(True)
    """)

    build_script = Path.join(dir, "scripts/build_site.sh")
    write!(dir, "scripts/build_site.sh", "#!/usr/bin/env bash\nmkdir -p \"$1\"\n")
    File.chmod!(build_script, 0o755)

    write!(dir, "scripts/check_site_links.py", """
    import os, sys
    if os.environ.get("SITE_CHECK_EXIT", "0") != "0":
        print("broken site link", file=sys.stderr)
        sys.exit(int(os.environ["SITE_CHECK_EXIT"]))
    """)
  end

  defp install_swift!(dir) do
    fixture = Path.join(dir, "bin/native-approval-geometry-fixture")
    File.cp!(Path.join(@root, "test/fixtures/native_approval_geometry_observer.py"), fixture)
    File.chmod!(fixture, 0o755)

    for path <- [
          "macos/Sources/AccountingFixture.swift",
          "macos/TestSupport/AccountingFixture.swift",
          "macos/.generated/AccountingFixture.swift",
          "macos/project.yml",
          "macos/Minga.xcodeproj/project.pbxproj"
        ] do
      write!(dir, path, "Synthetic native accounting fixture, not UI evidence.\n")
    end

    executable!(dir, "xcodebuild", ~S"""
    python3 - "$@" <<'PY'
    import json, os, plistlib, shutil, sys
    from pathlib import Path
    args = sys.argv[1:]
    derived = Path(args[args.index("-derivedDataPath") + 1]) if "-derivedDataPath" in args else Path.cwd() / "DerivedData"
    products = derived / "Build/Products"
    host = products / "Debug/MingaTestHost.app/Contents/MacOS/MingaTestHost"
    bare = "TEST_HOST=" in args
    if "MingaApprovalGeometry" in args and "-showBuildSettings" not in args:
        shutil.rmtree(host.parent.parent / "PlugIns", ignore_errors=True)
        observer = products / "Debug/minga-approval-geometry"
        observer.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path.cwd().parent / "bin/native-approval-geometry-fixture", observer)
        observer.chmod(0o755)
        host.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path.cwd().parent / "bin/native-approval-geometry-fixture", host)
        host.chmod(0o755)
        framework = products / "Debug/MingaUI.framework"
        framework.mkdir(exist_ok=True)
        (framework / "AccountingFixture").touch()
        sys.exit(0)
    if "-showBuildSettings" in args:
        if "build-for-testing" not in args:
            print(json.dumps([{"target":"Minga","action":"build","buildSettings":{}}]))
            sys.exit(0)
        bundle = products / ("Debug/MingaTests.xctest" if bare else "Debug/MingaTestHost.app/Contents/PlugIns/MingaTests.xctest")
        print(json.dumps([{"target":"MingaTests","buildSettings":{"TEST_HOST":"" if bare else str(host),"BUNDLE_LOADER":"" if bare else str(host),"TARGET_BUILD_DIR":str(bundle.parent),"FULL_PRODUCT_NAME":bundle.name}}]))
        sys.exit(0)
    bundle = products / ("Debug/MingaTests.xctest" if bare else "Debug/MingaTestHost.app/Contents/PlugIns/MingaTests.xctest")
    if "test-without-building" in args:
        if not bundle.is_dir() or not host.is_file():
            print("Missing hosted test product")
            sys.exit(70)
    else:
        bundle.mkdir(parents=True, exist_ok=True)
        if not bare:
            host.parent.mkdir(parents=True, exist_ok=True)
            host.touch()
    if "build-for-testing" in args:
        status = int(os.environ.get("HOSTED_BUILD_EXIT", "0"))
        if status == 0:
            target = {"BlueprintName":"MingaTests","TestHostPath":"__TESTROOT__/Debug/MingaTestHost.app","TestBundlePath":"__TESTHOST__/Contents/PlugIns/MingaTests.xctest","EnvironmentVariables":{"MINGA_TEST_PRODUCTION_APP_PATH":"__TESTROOT__/Debug/Minga.app"}}
            (products / "MingaUnitTests_macosx.xctestrun").write_bytes(plistlib.dumps({"__xctestrun_metadata__":{"FormatVersion":1},"MingaTests":target}))
        sys.exit(status)
    print("NOISY TEST OUTPUT")
    policy = "-only-testing:MingaTests/EditorFocusPolicyTests" in args
    if bare:
        print("xctest[4100:123] native runtime")
    else:
        pid = 4101 if policy else 4102
        print(f"[MingaTestHost] didFinishLaunching pid={pid} bundle=com.minga.test-host executable={host}")
        print(f"[Focus application native fixture] startup pid={pid}")
    if os.environ.get("NO_RESULT", "0") == "0":
        Path(args[args.index("-resultBundlePath") + 1]).mkdir(parents=True)
    status = int(os.environ.get("SWIFT_EXIT", "0"))
    sys.exit(status)
    PY
    """)

    executable!(dir, "xcrun", ~S"""
    python3 - "$@" <<'PY'
    import json, os, sys
    from pathlib import Path
    args = sys.argv[1:]
    action = Path(args[-1]).stem
    failed = action == "ordinary" and os.environ.get("SWIFT_EXIT", "0") != "0"
    if "summary" in args:
        total = 14 if action == "focus-policy" else 2
        print(json.dumps({"totalTestCount":total,"passedTests":total-int(failed),"failedTests":int(failed),"result":"Failed" if failed else "Passed"}))
        sys.exit(0)
    def case(identifier, result="Passed"):
        return {"nodeType":"Test Case","nodeIdentifier":identifier,"result":result}
    if action == "focus-policy":
        functions = ["pickerBeforeKeyWindow","promptAfterNativeModal","inlineHierarchyRebuild","keyframeRestoresOwner","nativeFieldDefersOwner","dismantlingFieldAppliesPendingOwner","markedTextDefersOwner","localLeasesDeferLatestOwner","iconSearchMirrorFocusesNativeField","lifecycleAppliesOnlyDecodedOwner","inlineStemSelectionPrecedesTyping","productionInlineRebuildDoesNotCommit","productionFieldsRegisterAfterLateInjection","actMenuReclaimsAndReturnsQueryFocus"]
        node = {"nodeType":"Test Suite","nodeIdentifier":"EditorFocusPolicyTests","result":"Passed","children":[case(f"EditorFocusPolicyTests/{name}()") for name in functions]}
    elif action == "focus-replay":
        replay = case("FocusReplayWindowTests/replay(_:)")
        replay["children"] = [{"nodeType":"Arguments","name":name,"result":"Passed"} for name in ["picker_open_close","search_open_close","rename_confirm","rename_cancel","agent_toggle","reattach_keyframe","hover_and_empty"]]
        node = {"nodeType":"Test Suite","nodeIdentifier":"FocusReplayWindowTests","result":"Passed","children":[case("FocusReplayWindowTests/corpusIsEnumerated()"),replay]}
    else:
        result = "Failed" if failed else "Passed"
        node = {"nodeType":"Test Suite","result":result,"children":[case("RenderingTests/testCaret()",result),case("RenderingTests/testPassing()")]}
    print(json.dumps({"testNodes":[node]}))
    PY
    """)
  end

  defp native_results(dir) do
    dir
    |> Path.join("results/native-unit/results.json")
    |> File.read!()
    |> Jason.decode!()
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
