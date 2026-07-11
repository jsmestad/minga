defmodule Minga.Test.LLMFormatterTest do
  # capture_io replaces the global IO device, and one test starts a nested Mix process.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  import ExUnit.CaptureIO

  alias Minga.Test.LLMFormatter

  test "reports no runnable tests as a passing result" do
    output =
      capture_io(fn ->
        {:ok, config} = LLMFormatter.init(seed: 123, max_cases: 1)

        assert {:noreply, _config} =
                 LLMFormatter.handle_cast(
                   {:suite_finished, %{run: 0, async: nil, load: nil}},
                   config
                 )
      end)

    assert output =~ "PASS: 0 tests, 0 failures"
  end

  test "omits rerun locations for module-only failures" do
    output =
      capture_io(fn ->
        {:ok, config} = LLMFormatter.init(seed: 123, max_cases: 1)

        config = %{
          config
          | failure_counter: 1,
            module_results: %{
              setup_failure: %{
                passed: 0,
                failed: 1,
                time_us: 0,
                file: "test/setup_failure_test.exs"
              }
            }
        }

        assert {:noreply, _config} =
                 LLMFormatter.handle_cast(
                   {:suite_finished, %{run: 0, async: nil, load: nil}},
                   config
                 )
      end)

    assert output =~ "Modules: 0 passed, 1 failed"
    assert output =~ "Failed modules:"
    assert output =~ "FAIL: 0 tests, 1 failure"
    refute output =~ "Failed test locations"
  end

  test "does not double-count failures when module teardown also fails", %{tmp_dir: tmp_dir} do
    fixture = Path.join(tmp_dir, "formatter_teardown_failure_test.exs")

    File.write!(fixture, """
    defmodule Minga.Test.LLMFormatterTeardownFailureFixture do
      use ExUnit.Case, async: true

      setup_all do
        on_exit(fn -> raise "fixture teardown failure" end)
        :ok
      end

      test "passes before teardown" do
        assert true
      end

      test "fails before teardown" do
        flunk("fixture test failure")
      end
    end
    """)

    {output, exit_status} =
      System.cmd("mix", ["test", "--formatter", "Minga.Test.LLMFormatter", fixture],
        stderr_to_stdout: true
      )

    assert exit_status != 0
    assert output =~ "Modules: 0 passed, 1 failed"
    assert output =~ "FAIL: 2 tests, 2 failures"
    refute output =~ "FAIL: 2 tests, 3 failures"
  end

  test "summarizes modules and retains failed module details" do
    output =
      capture_io(fn ->
        {:ok, config} = LLMFormatter.init(seed: 123, max_cases: 1)

        config = %{
          config
          | module_results: %{
              fast: %{passed: 2, failed: 0, time_us: 1_000, file: "test/fast_test.exs"},
              slow: %{passed: 3, failed: 0, time_us: 20_000, file: "test/slow_test.exs"},
              failed: %{passed: 1, failed: 1, time_us: 5_000, file: "test/failed_test.exs"}
            }
        }

        assert {:noreply, _config} =
                 LLMFormatter.handle_cast(
                   {:suite_finished, %{run: 0, async: nil, load: nil}},
                   config
                 )
      end)

    assert output =~ "Modules: 2 passed, 1 failed"
    assert output =~ "Slowest passing modules:"
    assert output =~ "PASS test/slow_test.exs (3 tests, 20ms)"
    assert output =~ "Failed modules:"
    assert output =~ "FAIL test/failed_test.exs (2 tests, 5ms)"
  end
end
