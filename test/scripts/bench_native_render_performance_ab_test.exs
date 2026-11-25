# This module launches the benchmark driver and Git in an isolated temporary repository.
defmodule Minga.BenchNativeRenderPerformanceAbTest do
  use ExUnit.Case, async: false

  # A temporary Git repository and a stub runner prove the driver's hosted control flow.
  # The module runs in test.heavy.
  @moduletag :heavy
  @moduletag timeout: 60_000

  @root Path.expand("../..", __DIR__)
  @script Path.join(@root, "scripts/bench_native_render_performance_ab")
  @git_env [
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_AUTHOR_NAME", "Bench Test"},
    {"GIT_AUTHOR_EMAIL", "bench@example.com"},
    {"GIT_COMMITTER_NAME", "Bench Test"},
    {"GIT_COMMITTER_EMAIL", "bench@example.com"}
  ]

  # The driver reads these from the measured revision; the stub runner never opens them.
  @ruler_paths [
    "macos/project.yml",
    "macos/Sources/Protocol/RenderPerformanceGate.swift",
    "macos/Tests/NativePerformance/NativeRenderPerformanceMain.swift",
    "macos/Tests/NativePerformance/FrameStagingReplay.swift",
    "macos/Tests/Performance/NativeCompare/main.swift"
  ]

  # Records each call, writes a measurement, and exits with the status the test scripted for that call.
  @stub_runner """
  #!/usr/bin/env bash
  set -u
  mode=$1
  shift
  case "$mode" in
    --build)
      echo "build" >> "$STUB_LOG"
      ;;
    --measure)
      echo "measure" >> "$STUB_LOG"
      echo "{}" > "$2"
      if [[ "$(grep -c '^measure$' "$STUB_LOG")" == "${STUB_FAIL_MEASURE_AT:-0}" ]]; then
        exit 2
      fi
      ;;
    --compare)
      shift
      echo "compare $*" >> "$STUB_LOG"
      read -r -a statuses <<< "$STUB_COMPARE_STATUSES"
      exit "${statuses[$(grep -c '^compare ' "$STUB_LOG") - 1]}"
      ;;
  esac
  """

  setup_all do
    dir = Path.join(System.tmp_dir!(), "minga-bench-native-#{System.unique_integer([:positive])}")
    stub_bin = Path.join(dir, "stub-bin")
    on_exit(fn -> File.rm_rf!(dir) end)

    write!(dir, "scripts/check_native_render_performance", @stub_runner)

    File.cp!(
      Path.join(@root, "scripts/check_native_render_measurement_result"),
      Path.join(dir, "scripts/check_native_render_measurement_result")
    )

    Enum.each(@ruler_paths, &write!(dir, &1, "placeholder\n"))

    # The driver generates protocol sources with mix; the stub keeps the real task out of the test.
    write!(dir, "stub-bin/mix", "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(Path.join(stub_bin, "mix"), 0o755)

    git!(dir, ["init", "--quiet"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--quiet", "-m", "benchmark fixture"])

    %{repo: dir, stub_bin: stub_bin}
  end

  test "three hosted runs that pass the verdict need no confirmation", context do
    assert {_output, 0, calls} = run_head_only(context, compare_statuses: "0")

    assert Enum.count(calls, &(&1 == "measure")) == 3
    assert [compare] = compares(calls)
    assert compare =~ "--hosted"
    assert head_count(compare) == 3
  end

  test "a wall-clock breach in all three runs is judged again over seven runs", context do
    assert {output, 0, calls} = run_head_only(context, compare_statuses: "3 0")

    assert output =~ "collecting four confirmation runs"
    assert Enum.count(calls, &(&1 == "measure")) == 7
    assert [first, second] = compares(calls)
    assert head_count(first) == 3
    assert second =~ "--hosted"
    assert head_count(second) == 7
  end

  test "a wall-clock breach that the confirmation runs repeat fails the gate", context do
    assert {_output, 3, calls} = run_head_only(context, compare_statuses: "3 3")

    assert Enum.count(calls, &(&1 == "measure")) == 7
    assert [_first, _second] = compares(calls)
  end

  test "a failure found by the confirmation verdict fails the gate", context do
    assert {_output, 1, calls} = run_head_only(context, compare_statuses: "3 1")

    assert Enum.count(calls, &(&1 == "measure")) == 7
    assert [_first, _second] = compares(calls)
  end

  test "a CPU, counter, or tool failure is final after three runs", context do
    for status <- [1, 2] do
      assert {output, ^status, calls} =
               run_head_only(context, compare_statuses: Integer.to_string(status))

      refute output =~ "confirmation"
      assert Enum.count(calls, &(&1 == "measure")) == 3
      assert [_only] = compares(calls)
    end
  end

  test "a failed confirmation measurement fails the gate without a second verdict", context do
    assert {_output, 1, calls} =
             run_head_only(context, compare_statuses: "3", fail_measure_at: 5)

    assert Enum.count(calls, &(&1 == "measure")) == 5
    assert [_only] = compares(calls)
  end

  @spec run_head_only(map(), keyword()) :: {String.t(), non_neg_integer(), [String.t()]}
  defp run_head_only(%{repo: repo, stub_bin: stub_bin}, opts) do
    run_dir = Path.join(repo, "run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(run_dir)
    log = Path.join(run_dir, "calls.log")

    env =
      @git_env ++
        [
          {"PATH", stub_bin <> ":" <> System.get_env("PATH")},
          # The driver writes its evidence files here; CI sets this variable to the real checkout.
          {"GITHUB_WORKSPACE", run_dir},
          {"TMPDIR", run_dir},
          {"STUB_LOG", log},
          {"STUB_COMPARE_STATUSES", Keyword.fetch!(opts, :compare_statuses)},
          {"STUB_FAIL_MEASURE_AT", Integer.to_string(Keyword.get(opts, :fail_measure_at, 0))}
        ]

    {output, status} =
      System.cmd("bash", [@script, "--head-only", "HEAD"],
        cd: repo,
        env: env,
        stderr_to_stdout: true
      )

    {output, status, log |> File.read!() |> String.split("\n", trim: true)}
  end

  @spec compares([String.t()]) :: [String.t()]
  defp compares(calls), do: Enum.filter(calls, &String.starts_with?(&1, "compare "))

  @spec head_count(String.t()) :: non_neg_integer()
  defp head_count(compare) do
    compare |> String.split(" ") |> Enum.count(&(&1 == "--head"))
  end

  @spec write!(Path.t(), Path.t(), String.t()) :: :ok
  defp write!(dir, rel_path, content) do
    path = Path.join(dir, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  @spec git!(Path.t(), [String.t()]) :: :ok
  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: @git_env) do
      {_output, 0} -> :ok
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{output}")
    end
  end
end
