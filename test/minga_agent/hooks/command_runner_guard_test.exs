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

  test "a hook that was given a directory is started there" do
    hook = %Hook{
      event: :pre_tool_use,
      tool_pattern: "*",
      command: "scripts/check.sh",
      cwd: "/work/app"
    }

    payload = PreToolUsePayload.new("tc_1", "shell", %{})

    # What the helper answers does not matter here, only where it is started.
    %Result{} =
      CommandRunner.run_pre_tool_use(hook, payload,
        helper_path: "fake-helper",
        helper_backend: FakeHelperBackend,
        helper_backend_opts: [observer: self(), events: [{:exit_status, 0}]]
      )

    assert_receive {:fake_helper, helper_id, :started, _args, _payload_json}
    assert_receive {:fake_helper, ^helper_id, :directory, "/work/app"}
  end

  test "a hook without a directory runs in the project whose config is in effect, and nowhere special without one" do
    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: "scripts/check.sh"}
    payload = PreToolUsePayload.new("tc_1", "shell", %{})

    run = fn project_directory ->
      CommandRunner.run_pre_tool_use(hook, payload,
        helper_path: "fake-helper",
        helper_backend: FakeHelperBackend,
        helper_backend_opts: [observer: self(), events: [{:exit_status, 0}]],
        project_directory: project_directory
      )
    end

    %Result{} = run.("/work/app")
    assert_receive {:fake_helper, helper_id, :started, _args, _payload_json}
    assert_receive {:fake_helper, ^helper_id, :directory, "/work/app"}

    %Result{} = run.(nil)
    assert_receive {:fake_helper, other_id, :started, _args, _payload_json}
    refute_receive {:fake_helper, ^other_id, :directory, _directory}, 50
  end

  test "a hook declaration carries its directory, and an extension's hook cannot choose one" do
    assert {:ok, %Hook{cwd: "/work/app"}} =
             Hook.normalize(%{event: :stop, command: "scripts/done.sh", cwd: "/work/app"})

    assert {:ok, %Hook{cwd: nil}} = Hook.normalize(%{event: :stop, command: "scripts/done.sh"})

    assert {:error, "agent hook cwd must be a path" <> _rest} =
             Hook.normalize(%{event: :stop, command: "x", cwd: 7})
  end

  defp advancing_clock(step_ms) do
    counter = :counters.new(1, [])

    fn ->
      :counters.add(counter, 1, step_ms)
      :counters.get(counter, 1)
    end
  end
end
