defmodule MingaAgent.Tools.SubagentTest do
  use ExUnit.Case, async: true

  alias Minga.Events
  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaAgent.Subagent.Handle
  alias MingaAgent.Tools.Subagent
  alias Minga.Test.SubagentErrorProvider, as: ErrorProvider
  alias Minga.Test.SubagentGatedProvider, as: GatedProvider
  alias Minga.Test.SubagentOverrideProvider, as: OverrideProvider
  alias Minga.Test.SubagentRecordingProvider, as: RecordingProvider
  alias Minga.Test.SubagentTestNotifier, as: TestNotifier
  alias Minga.Test.SubagentWorktreeBackend
  alias Minga.Test.SubagentWorktreeProvider
  alias ReqLLM.StreamResponse.MetadataHandle
  alias ReqLLM.StreamChunk

  @moduletag :tmp_dir
  @event_timeout 15_000

  # ── Setup ──────────────────────────────────────────────────────────────────

  setup context do
    if context[:session_manager], do: start_session_manager(), else: :ok
  end

  # ── Background subagent tests ──────────────────────────────────────────────

  @tag :session_manager
  test "background subagent returns a stable handle before the child finishes", %{
    manager: manager
  } do
    test_pid = self()

    Events.subscribe(:background_subagent_started)

    assert {:ok, result} =
             Subagent.execute("long task",
               background: true,
               session_manager: manager,
               provider: GatedProvider,
               provider_opts: [test_pid: test_pid]
             )

    assert result =~ ~r/Handle: session-1-[0-9a-f]{8}/

    assert_receive {:minga_event, :background_subagent_started,
                    %Handle{session_id: session_id, task: "long task"}},
                   @event_timeout

    assert String.match?(session_id, ~r/^session-1-[0-9a-f]{8}$/)

    [handle] = SessionManager.list_background_subagents(manager, nil)
    assert %Handle{session_id: ^session_id, pid: child_pid} = handle
    assert Session.status(child_pid) in [:idle, :thinking]

    assert_receive {:provider_prompt, provider_pid, "long task"}, @event_timeout
    assert Session.status(child_pid) == :thinking

    assert :ok = GatedProvider.proceed(provider_pid)
    assert_eventually_idle(child_pid)
  end

  @tag :session_manager
  test "parent session remains usable while background child is running", %{manager: manager} do
    {:ok, _parent_id, parent_pid} =
      SessionManager.start_session(manager,
        provider: GatedProvider,
        provider_opts: [test_pid: self()]
      )

    {:ok, _result} =
      Subagent.execute("child work",
        background: true,
        session_manager: manager,
        parent_session: parent_pid,
        provider: GatedProvider,
        provider_opts: [test_pid: self()]
      )

    assert_receive {:provider_prompt, _provider_pid, "child work"}, @event_timeout
    [handle] = SessionManager.list_background_subagents(manager, parent_pid)
    assert handle.parent_pid == parent_pid

    :ok = Session.add_system_message(parent_pid, "parent still responsive")

    assert Enum.any?(
             Session.messages(parent_pid),
             &(&1 == {:system, "parent still responsive", :info})
           )
  end

  @tag :session_manager
  test "background child result remains available in child chat", %{manager: manager} do
    {:ok, _result} =
      Subagent.execute("write result",
        background: true,
        session_manager: manager,
        provider: GatedProvider,
        provider_opts: [test_pid: self()]
      )

    [handle] = SessionManager.list_background_subagents(manager, nil)
    Session.subscribe(handle.pid)
    assert_receive {:provider_prompt, provider_pid, "write result"}, @event_timeout
    :ok = GatedProvider.proceed(provider_pid, "saved answer")
    assert_receive {:agent_event, _pid, {:status_changed, :idle}}, @event_timeout

    assert Enum.any?(Session.messages(handle.pid), &(&1 == {:assistant, "saved answer"}))
  end

  @tag :session_manager
  test "background child error remains available in child chat and notifies once", %{
    manager: manager
  } do
    {:ok, _result} =
      Subagent.execute("fail",
        background: true,
        session_manager: manager,
        provider: ErrorProvider,
        provider_opts: [test_pid: self()],
        notifier: {TestNotifier, self()}
      )

    [handle] = SessionManager.list_background_subagents(manager, nil)
    Session.subscribe(handle.pid)
    assert_receive {:provider_prompt, _provider_pid, "fail"}, @event_timeout
    assert Session.status(handle.pid) == :error
    assert_receive {:notified, :error, "boom"}, @event_timeout
    refute_receive {:notified, :error, _}, 50

    assert Session.status(handle.pid) == :error
    assert Enum.any?(Session.messages(handle.pid), &(&1 == {:system, "boom", :error}))
  end

  @tag :session_manager
  test "background child completion notifies once", %{manager: manager} do
    {:ok, _result} =
      Subagent.execute("notify",
        background: true,
        session_manager: manager,
        provider: GatedProvider,
        provider_opts: [test_pid: self()],
        notifier: {TestNotifier, self()}
      )

    [handle] = SessionManager.list_background_subagents(manager, nil)
    Session.subscribe(handle.pid)
    assert_receive {:provider_prompt, provider_pid, "notify"}, @event_timeout
    :ok = GatedProvider.proceed(provider_pid)
    assert_receive {:agent_event, _pid, {:status_changed, :idle}}, @event_timeout
    assert_receive {:notified, :complete, message}, @event_timeout
    assert String.match?(message, ~r/^Sub-agent session-1-[0-9a-f]{8} finished$/)
    refute_receive {:notified, :complete, _}, 50
  end

  @tag :session_manager
  test "background native subagent rejects destructive tools immediately without an approval driver",
       %{
         manager: manager,
         tmp_dir: dir
       } do
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, _result} =
             Subagent.execute("write through native tool",
               background: true,
               session_manager: manager,
               project_root: dir,
               provider: MingaAgent.Providers.Native,
               model: "anthropic:claude-sonnet-4-20250514",
               provider_opts: [
                 llm_client: native_write_client("child.txt", "from native\n", "write rejected"),
                 skip_api_key_env: true
               ]
             )

    [handle] = SessionManager.list_background_subagents(manager, nil)
    Session.subscribe(handle.pid)

    assert_receive {:agent_event, _pid,
                    {:approval_rejected, "tc_write_file", "write_file", message}},
                   @event_timeout

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms < 2_000
    assert message =~ "no interactive approval driver"
    assert_eventually_idle(handle.pid)
    refute File.exists?(Path.join(dir, "child.txt"))

    assert {:tool_call, tool_call} =
             Enum.find(
               Session.messages(handle.pid),
               &match?({:tool_call, %{id: "tc_write_file"}}, &1)
             )

    assert tool_call.status == :error
    assert tool_call.result == message
  end

  # ── Foreground subagent tests ──────────────────────────────────────────────

  test "foreground subagent still blocks and returns final text" do
    test_pid = self()

    task =
      Task.async(fn ->
        Subagent.execute("foreground",
          provider: GatedProvider,
          provider_opts: [test_pid: test_pid]
        )
      end)

    assert_receive {:provider_prompt, provider_pid, "foreground"}, @event_timeout
    :ok = GatedProvider.proceed(provider_pid, "foreground done")
    assert {:ok, "foreground done"} = Task.await(task, @event_timeout)
  end

  test "worktree-isolated subagent preserves a changed worktree", %{tmp_dir: dir} do
    root = fake_git_root!(dir)

    assert {:ok, result} =
             Subagent.execute("write",
               isolation: "worktree",
               project_root: root,
               provider: SubagentWorktreeProvider,
               worktree_backend: SubagentWorktreeBackend,
               worktree_backend_opts: fake_worktree_opts(root)
             )

    assert result =~ "wrote file"
    assert [_, worktree_path] = Regex.run(~r/Worktree: (.+)/, result)
    assert [_, "subagent/" <> _id] = Regex.run(~r/Branch: (.+)/, result)
    assert File.read!(Path.join(worktree_path, "child.txt")) == "from child\n"
    refute File.exists?(Path.join(root, "child.txt"))
  end

  test "worktree-isolated native subagent auto-approves destructive tools", %{tmp_dir: dir} do
    root = fake_git_root!(dir)

    assert {:ok, result} =
             Subagent.execute("write through native tool",
               isolation: "worktree",
               project_root: root,
               worktree_backend: SubagentWorktreeBackend,
               worktree_backend_opts: fake_worktree_opts(root),
               provider: MingaAgent.Providers.Native,
               model: "anthropic:claude-sonnet-4-20250514",
               provider_opts: [
                 llm_client: native_write_client("child.txt", "from native\n", "native wrote"),
                 skip_api_key_env: true
               ]
             )

    assert result =~ "native wrote"
    assert [_, worktree_path] = Regex.run(~r/Worktree: (.+)/, result)
    assert File.read!(Path.join(worktree_path, "child.txt")) == "from native\n"
    refute File.exists?(Path.join(root, "child.txt"))
  end

  test "worktree-isolated subagent removes a clean no-op worktree", %{tmp_dir: dir} do
    root = fake_git_root!(dir)

    assert {:ok, "no changes"} =
             Subagent.execute("noop",
               isolation: "worktree",
               project_root: root,
               provider: SubagentWorktreeProvider,
               worktree_backend: SubagentWorktreeBackend,
               worktree_backend_opts: fake_worktree_opts(root)
             )

    assert_receive {:worktree_command, ^root,
                    ["worktree", "add", "-b", branch, worktree_path, "test-base-sha"]}

    assert_receive {:worktree_command, ^root, ["worktree", "remove", "--force", ^worktree_path]}

    assert_receive {:worktree_command, ^root, ["branch", "-D", ^branch]}
    refute File.exists?(worktree_path)
  end

  test "worktree-isolated subagent preserves the child when cleanliness inspection fails", %{
    tmp_dir: dir
  } do
    root = fake_git_root!(dir)

    assert {:ok, result} =
             Subagent.execute("noop",
               isolation: "worktree",
               project_root: root,
               provider: SubagentWorktreeProvider,
               worktree_backend: SubagentWorktreeBackend,
               worktree_backend_opts: fake_worktree_opts(root, inspection_error: true)
             )

    assert [_, worktree_path] = Regex.run(~r/Worktree: (.+)/, result)
    assert result =~ "Branch: subagent/"
    assert File.dir?(worktree_path)
    refute_received {:worktree_command, ^root, ["worktree", "remove" | _rest]}
  end

  test "worktree-isolated subagent returns preserved worktree metadata after dirty error", %{
    tmp_dir: dir
  } do
    root = fake_git_root!(dir)

    assert {:error, message} =
             Subagent.execute("write-error",
               isolation: "worktree",
               project_root: root,
               provider: SubagentWorktreeProvider,
               worktree_backend: SubagentWorktreeBackend,
               worktree_backend_opts: fake_worktree_opts(root)
             )

    assert message =~ "failed after write"
    assert [_, worktree_path] = Regex.run(~r/Worktree: (.+)/, message)
    assert message =~ "Branch: subagent/"
    assert File.read!(Path.join(worktree_path, "child.txt")) == "from child\n"
  end

  test "worktree-isolated subagent refuses a dirty repository", %{tmp_dir: dir} do
    root = fake_git_root!(dir)

    assert {:error, message} =
             Subagent.execute("noop",
               isolation: "worktree",
               project_root: root,
               provider: SubagentWorktreeProvider,
               worktree_backend: SubagentWorktreeBackend,
               worktree_backend_opts: fake_worktree_opts(root, dirty_parent: true)
             )

    assert message =~ "requires a clean git tree"
    refute_received {:worktree_command, ^root, ["worktree", "add" | _rest]}
  end

  @tag :session_manager
  test "worktree-isolated background native subagent auto-approves destructive tools", %{
    manager: manager,
    tmp_dir: dir
  } do
    root = fake_git_root!(dir)

    assert {:ok, result} =
             Subagent.execute("write through native tool",
               isolation: "worktree",
               background: true,
               session_manager: manager,
               project_root: root,
               worktree_backend: SubagentWorktreeBackend,
               worktree_backend_opts: fake_worktree_opts(root),
               provider: MingaAgent.Providers.Native,
               model: "anthropic:claude-sonnet-4-20250514",
               provider_opts: [
                 llm_client:
                   native_write_client(
                     "background-child.txt",
                     "from background native\n",
                     "background native wrote"
                   ),
                 skip_api_key_env: true
               ]
             )

    assert result =~ "Background subagent started"
    assert [_, worktree_path] = Regex.run(~r/Worktree: (.+)/, result)
    [handle] = SessionManager.list_background_subagents(manager, nil)
    Session.subscribe(handle.pid)

    assert_receive {:agent_event, _pid,
                    {:tool_auto_approved, "tc_write_file", "write_file", :session}},
                   @event_timeout

    assert_eventually_idle(handle.pid)

    assert File.read!(Path.join(worktree_path, "background-child.txt")) ==
             "from background native\n"

    refute File.exists?(Path.join(root, "background-child.txt"))
  end

  # ── Context inheritance tests ──────────────────────────────────────────────

  describe "execute/2 context inheritance" do
    test "inherits parent provider model thinking level and active skills by default", %{
      tmp_dir: dir
    } do
      ref = make_ref()
      parent = start_parent_session(dir, ref)

      assert {:ok, "child response"} =
               Subagent.execute("do child task",
                 parent_session: parent,
                 project_root: dir,
                 provider_opts: [test_pid: self(), test_ref: ref]
               )

      assert_child_started(ref, fn opts ->
        assert Keyword.fetch!(opts, :model) == "parent-model"
        assert Keyword.fetch!(opts, :provider) == "recording"
        assert Keyword.fetch!(opts, :thinking_level) == "high"
        assert Keyword.fetch!(opts, :active_skill_names) == ["plan", "review"]
        assert Keyword.fetch!(opts, :project_root) == dir
      end)
    end

    test "explicit model override wins while other parent context is inherited", %{tmp_dir: dir} do
      ref = make_ref()
      parent = start_parent_session(dir, ref)

      assert {:ok, "child response"} =
               Subagent.execute("do child task",
                 parent_session: parent,
                 project_root: dir,
                 model: "override-model",
                 provider_opts: [test_pid: self(), test_ref: ref]
               )

      assert_child_started(ref, fn opts ->
        assert Keyword.fetch!(opts, :model) == "override-model"
        assert Keyword.fetch!(opts, :provider) == "recording"
        assert Keyword.fetch!(opts, :thinking_level) == "high"
        assert Keyword.fetch!(opts, :active_skill_names) == ["plan", "review"]
      end)
    end

    test "explicit provider override wins over the parent provider", %{tmp_dir: dir} do
      ref = make_ref()
      parent = start_parent_session(dir, ref)

      assert {:ok, "child response"} =
               Subagent.execute("do child task",
                 parent_session: parent,
                 project_root: dir,
                 provider: OverrideProvider,
                 provider_opts: [test_pid: self(), test_ref: ref]
               )

      assert_child_started(ref, fn opts ->
        assert Keyword.fetch!(opts, :provider) == inspect(OverrideProvider)
        assert Keyword.fetch!(opts, :model) == "parent-model"
        assert Keyword.fetch!(opts, :thinking_level) == "high"
        assert Keyword.fetch!(opts, :active_skill_names) == ["plan", "review"]
      end)
    end

    test "explicit provider and model overrides are visible in the child first system message", %{
      tmp_dir: dir
    } do
      ref = make_ref()
      test_pid = self()

      task =
        Task.async(fn ->
          Subagent.execute("do child task",
            project_root: dir,
            provider: OverrideProvider,
            model: "override-model",
            provider_opts: [test_pid: test_pid, test_ref: ref, blocking: true]
          )
        end)

      assert_receive {^ref, {:prompt_received, provider_pid, child_session, "do child task"}},
                     @event_timeout

      [{:system, first_system_message, :info} | _rest] = Session.messages(child_session)
      assert first_system_message =~ "Subagent overrides"
      assert first_system_message =~ "provider override: #{inspect(OverrideProvider)}"
      assert first_system_message =~ "model override: override-model"

      RecordingProvider.finish(provider_pid)
      assert {:ok, "blocked child response"} = Task.await(task, @event_timeout)
    end

    test "falls back to default context when parent session is already dead", %{tmp_dir: dir} do
      ref = make_ref()
      parent = start_parent_session(dir, ref)
      monitor_ref = Process.monitor(parent)
      assert :ok = MingaAgent.Supervisor.stop_session(parent)
      assert_receive {:DOWN, ^monitor_ref, :process, ^parent, _reason}, @event_timeout

      assert {:ok, "child response"} =
               Subagent.execute("do child task",
                 project_root: dir,
                 parent_session: parent,
                 provider: RecordingProvider,
                 provider_opts: [test_pid: self(), test_ref: ref]
               )

      assert_child_started(ref, fn opts ->
        refute Keyword.has_key?(opts, :thinking_level)
        assert Keyword.get(opts, :active_skill_names, []) == []
      end)
    end

    test "stops the child session after success", %{tmp_dir: dir} do
      ref = make_ref()
      parent = start_parent_session(dir, ref)

      assert {:ok, "child response"} =
               Subagent.execute("do child task",
                 parent_session: parent,
                 project_root: dir,
                 provider_opts: [test_pid: self(), test_ref: ref]
               )

      assert_receive {^ref, {:prompt_received, _provider_pid, child_session, "do child task"}},
                     @event_timeout

      monitor_ref = Process.monitor(child_session)
      assert_receive {:DOWN, ^monitor_ref, :process, ^child_session, _reason}, @event_timeout
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp assert_eventually_idle(session_pid) do
    Session.subscribe(session_pid)

    if Session.status(session_pid) == :idle do
      :ok
    else
      receive do
        {:agent_event, ^session_pid, {:status_changed, :idle}} -> :ok
      after
        @event_timeout -> flunk("session did not become idle")
      end
    end
  end

  @spec start_parent_session(String.t(), reference()) :: pid()
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

  @spec assert_child_started(reference(), (keyword() -> any())) :: :ok
  defp assert_child_started(ref, assertions) do
    assert_receive {^ref, {:provider_started, _provider_pid, opts}}, @event_timeout
    assertions.(opts)
    :ok
  end

  @spec native_write_client(String.t(), String.t(), String.t()) :: function()
  defp native_write_client(path, content, final_text) do
    call_count = :counters.new(1, [:atomics])

    fn _model, _messages, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            StreamChunk.tool_call(
              "write_file",
              %{"path" => path, "content" => content},
              %{id: "tc_write_file", index: 0}
            ),
            StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [StreamChunk.text(final_text), StreamChunk.meta(%{finish_reason: :stop})]
        end

      build_stream_response(chunks)
    end
  end

  @spec build_stream_response([StreamChunk.t()]) ::
          {:ok, ReqLLM.StreamResponse.t()}
  defp build_stream_response(chunks) do
    {:ok, handle} =
      MetadataHandle.start_link(fn ->
        %{usage: %{}, finish_reason: :stop}
      end)

    stream_response = %ReqLLM.StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: elem(ReqLLM.model("anthropic:claude-sonnet-4-20250514"), 1),
      context: ReqLLM.Context.new()
    }

    {:ok, stream_response}
  end

  @spec start_session_manager() :: map()
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

    %{manager: manager}
  end

  @spec fake_git_root!(String.t()) :: String.t()
  defp fake_git_root!(dir) do
    root = Path.join(dir, "repo")
    File.mkdir_p!(root)
    root
  end

  @spec fake_worktree_opts(String.t(), keyword()) :: keyword()
  defp fake_worktree_opts(root, extra \\ []) do
    Keyword.merge([root: root, test_pid: self()], extra)
  end
end
