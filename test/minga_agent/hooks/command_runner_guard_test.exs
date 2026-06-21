defmodule MingaAgent.Hooks.CommandRunnerGuardTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.CommandRunner
  alias MingaAgent.Hooks.FakeHelperBackend
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result

  test "guard timeout stops a helper even while stdout keeps arriving" do
    clock = advancing_clock(250)
    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: "exit 0", timeout_ms: 10}
    payload = PreToolUsePayload.new("tc_1", "shell", %{})

    assert %Result{status: :veto, reason: {:failed_to_start, :helper_timeout}, stderr: stderr} =
             CommandRunner.run_pre_tool_use(hook, payload,
               helper_path: "fake-helper",
               helper_backend: FakeHelperBackend,
               helper_backend_opts: [observer: self(), events: :repeat_data],
               clock: clock
             )

    assert stderr =~ "hook runner timed out after 1010ms"

    assert_receive {:fake_helper, helper_id, :started, ["10", _payload_size, "exit 0"],
                    _payload_json}

    assert_receive {:fake_helper, ^helper_id, :stopped}
  end

  defp advancing_clock(step_ms) do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, step_ms)
      :counters.get(counter, 1)
    end
  end
end
