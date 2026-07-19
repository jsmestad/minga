defmodule MingaAgent.Tools.SubagentTest do
  use ExUnit.Case, async: true

  alias Minga.Events
  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaAgent.Subagent.Handle
  alias MingaAgent.Tools.Subagent
  alias Minga.Test.SubagentGatedProvider, as: GatedProvider
  alias Minga.Test.SubagentRecordingProvider, as: RecordingProvider

  @moduletag :tmp_dir
  @event_timeout 15_000

  test "background execution returns a stable handle and preserves the child result" do
    manager = start_session_manager()
    Events.subscribe(:background_subagent_started)

    assert {:ok, result} =
             Subagent.execute("background task",
               background: true,
               session_manager: manager,
               provider: GatedProvider,
               provider_opts: [test_pid: self()]
             )

    assert result =~ ~r/Handle: session-1-[0-9a-f]{8}/

    assert_receive {:minga_event, :background_subagent_started,
                    %Handle{session_id: session_id, task: "background task"}},
                   @event_timeout

    assert_receive {:provider_prompt, provider_pid, "background task"}, @event_timeout
    [handle] = SessionManager.list_background_subagents(manager, nil)
    assert handle.session_id == session_id

    Session.subscribe(handle.pid)
    assert :ok = GatedProvider.proceed(provider_pid, "saved answer")
    assert_receive {:agent_event, _pid, {:status_changed, :idle}}, @event_timeout
    assert {:assistant, "saved answer"} in Session.messages(handle.pid)
  end

  test "foreground execution blocks until the child returns final text" do
    test_pid = self()

    task =
      Task.async(fn ->
        Subagent.execute("foreground",
          provider: GatedProvider,
          provider_opts: [test_pid: test_pid]
        )
      end)

    assert_receive {:provider_prompt, provider_pid, "foreground"}, @event_timeout
    assert :ok = GatedProvider.proceed(provider_pid, "foreground done")
    assert {:ok, "foreground done"} = Task.await(task, @event_timeout)
  end

  test "foreground startup timeout returns an error and stops the child session" do
    test_pid = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Subagent.execute("blocked startup",
          provider: GatedProvider,
          provider_opts: [test_pid: test_pid, startup_gate: {test_pid, ref}],
          startup_timeout_ms: 10
        )
      end)

    assert_receive {:provider_starting, ^ref, provider_pid, session_pid}, @event_timeout
    Process.send_after(provider_pid, {ref, :continue}, 50)
    monitor = Process.monitor(session_pid)

    assert {:error, "Subagent timed out while starting"} = Task.await(task, @event_timeout)
    assert_receive {:DOWN, ^monitor, :process, ^session_pid, _reason}, @event_timeout
  end

  test "inherits parent provider context by default", %{tmp_dir: dir} do
    ref = make_ref()
    parent = start_parent_session(dir, ref)

    assert {:ok, "child response"} =
             Subagent.execute("child task",
               parent_session: parent,
               project_root: dir,
               provider_opts: [test_pid: self(), test_ref: ref]
             )

    assert_receive {^ref, {:provider_started, _provider_pid, opts}}, @event_timeout
    assert Keyword.fetch!(opts, :model) == "parent-model"
    assert Keyword.fetch!(opts, :provider) == "recording"
    assert Keyword.fetch!(opts, :thinking_level) == "high"
    assert Keyword.fetch!(opts, :active_skill_names) == ["plan", "review"]
  end

  defp start_parent_session(dir, ref) do
    {:ok, parent} =
      MingaAgent.Supervisor.start_session(
        provider: RecordingProvider,
        model_name: "parent-model",
        provider_opts: [
          provider: "recording",
          model: "parent-model",
          thinking_level: "high",
          active_skill_names: ["plan", "review"],
          project_root: dir,
          test_pid: self(),
          test_ref: ref
        ]
      )

    assert_receive {^ref, {:provider_started, _provider_pid, opts}}, @event_timeout
    assert Keyword.fetch!(opts, :subscriber) == parent
    on_exit(fn -> MingaAgent.Supervisor.stop_session(parent) end)
    parent
  end

  defp start_session_manager do
    name = :"subagent_manager_#{System.unique_integer([:positive])}"
    {:ok, manager} = GenServer.start(SessionManager, [], name: name)

    on_exit(fn ->
      manager
      |> GenServer.call(:list_sessions)
      |> Enum.each(fn {session_id, _pid, _meta} ->
        GenServer.call(manager, {:stop_session, session_id})
      end)

      GenServer.stop(manager)
    end)

    manager
  end
end
