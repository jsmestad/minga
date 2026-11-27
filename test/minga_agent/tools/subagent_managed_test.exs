defmodule MingaAgent.Tools.SubagentManagedTest do
  # The isolation proof uses real Git worktrees and therefore spawns OS commands.
  use ExUnit.Case, async: false

  alias Minga.Config.Options
  alias Minga.Events
  alias Minga.Test.SubagentWorktreeBackend
  alias MingaAgent.Credentials
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Event
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.OAuth
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.Tool.Registry, as: ToolRegistry
  alias MingaAgent.ToolCall
  alias MingaAgent.Tools
  alias MingaEditor.Agent.SubagentPeekComposer, as: Composer
  alias MingaEditor.Session.State, as: Workspace
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse.MetadataHandle

  @moduletag :tmp_dir
  @timeout 5_000
  @model "openai:gpt-6.1-sol"
  @brief "same brief for both siblings"

  setup_all do
    assert [_ | _] = LLMDB.models()
    :ok
  end

  setup %{tmp_dir: dir} do
    suffix = System.unique_integer([:positive])
    events = :"subagent_events_#{suffix}"
    options = :"subagent_options_#{suffix}"
    tools = :"subagent_tools_#{suffix}"
    start_supervised!({Registry, name: events, keys: :duplicate})
    start_supervised!({Options, name: options, events_registry: events})
    assert {:ok, :none} = Options.set(options, :agent_tool_approval, :none)
    start_supervised!({ToolRegistry, name: tools})
    subagent = Enum.find(Tools.specs_for_source(:builtin), &(&1.name == "subagent"))
    assert :ok = ToolRegistry.register(tools, subagent)

    oauth_path = Path.join(dir, "credentials/oauth.json")

    assert :ok =
             OAuth.write_oauth_file(
               %{
                 access: "fixture-access",
                 refresh: "fixture-refresh",
                 expires: System.system_time(:millisecond) + 3_600_000,
                 account_id: "fixture-account"
               },
               oauth_path
             )

    credential_opts = [
      config_dir: Path.dirname(oauth_path),
      oauth_path: oauth_path,
      env: Map.new(Credentials.known_providers(), &{Credentials.env_var_for(&1), nil})
    ]

    resolver_opts =
      [model_id: "gpt-6.1-sol"]
      |> ModelSelectionFixture.resolver_opts()
      |> Keyword.delete(:credential_snapshot)

    provider_opts = [
      model: @model,
      model_resolver_opts: resolver_opts,
      config: %MingaAgent.Config{compaction_threshold: nil, tool_approval: :none},
      credential_opts: credential_opts,
      skip_api_key_env: true,
      tool_registry: tools,
      max_retries: 0
    ]

    supervisor =
      start_supervised!(
        {DynamicSupervisor, name: :"subagent_sessions_#{suffix}", strategy: :one_for_one}
      )

    root = Path.join(dir, "project")
    File.mkdir_p!(root)
    Events.subscribe(:foreground_subagent_changed)
    Events.subscribe(:foreground_subagent_disposed)

    %{
      suffix: suffix,
      root: root,
      options: options,
      supervisor: supervisor,
      provider_opts: provider_opts
    }
  end

  test "admitted same-brief siblings keep their exact roots and return only their first results",
       ctx do
    git!(ctx.root, ["init", "."])

    git!(ctx.root, [
      "-c",
      "user.name=Minga",
      "-c",
      "user.email=minga@example.com",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.hooksPath=/dev/null",
      "commit",
      "--allow-empty",
      "-m",
      "base"
    ])

    manager = start_manager(ctx)
    {parent_id, parent} = start_parent(ctx, manager, ["left", "right"])
    assert :ok = Session.send_prompt(parent, "fan out")

    left = await_child(parent_id, "left")
    {^parent_id, left_key} = left.identity

    assert_receive {:agent_event, ^parent,
                    {:tool_started,
                     %Event.ToolStart{tool_call_id: "left", invocation_key: ^left_key}}},
                   @timeout

    assert_receive {:child_request, left_turn, @brief}, @timeout
    assert {:ok, ^left} = SessionManager.foreground_subagent(manager, left.identity)

    assert {:error, :subagent_initial_request_active} =
             SessionManager.send_foreground_subagent_prompt(manager, left.identity, "too early")

    send(left_turn, {:answer, "left original"})
    assert_parent_result(parent, left, "left original")

    right = await_child(parent_id, "right")
    assert_receive {:child_request, right_turn, @brief}, @timeout
    refute left.session_id == right.session_id
    refute left.pid == right.pid
    refute left.project_root == right.project_root
    assert child_root(left) == left.project_root
    assert child_root(right) == right.project_root
    assert {:ok, %{writable?: true}} = SessionManager.foreground_subagent(manager, left.identity)
    assert {:ok, ^right} = SessionManager.foreground_subagent(manager, right.identity)

    nonce = "follow-up nonce #{ctx.suffix}"
    left_pid = left.pid
    assert :ok = Session.subscribe(left.pid)
    {draft, target} = composer_for(manager, left.identity)
    draft = draft |> Composer.edit(target, {:insert, nonce}) |> Composer.submit(target)
    draft = Composer.edit(draft, target, {:move, :left})
    left_identity = left.identity
    assert_receive {:subagent_peek_sent, ^left_identity, token, :ok}, @timeout
    draft = Composer.sent(draft, left_identity, token, :ok)

    assert {"", {0, 0}, false, nil} =
             Composer.presentation(draft.agent_connection.peek_composer, left_identity)

    assert_receive {:child_request, left_follow_up, ^nonce}, @timeout
    assert child_root(left) == left.project_root
    send(left_follow_up, {:answer, "nonce received"})
    assert_receive {:agent_event, ^left_pid, {:text_delta, "nonce received"}}, @timeout
    assert {:user, nonce} in Session.messages(left.pid)
    refute {:user, nonce} in Session.messages(right.pid)
    refute {:user, nonce} in Session.messages(parent)

    send(right_turn, {:answer, "right original"})
    assert_parent_result(parent, right, "right original")
    assert_receive {:agent_event, ^parent, {:status_changed, :idle}}, @timeout

    assert Enum.map(parent_results(parent), & &1.id) == ["left", "right"]
    refute_receive {:agent_event, ^parent, {:tool_ended, %Event.ToolEnd{name: "subagent"}}}, 0

    file = Path.join(right.project_root, "user-change.txt")
    File.write!(file, "keep this work")
    left_provider = Session.get_provider(left.pid)
    provider_monitor = Process.monitor(left_provider)
    left_monitor = Process.monitor(left.pid)
    # A registered effect may still be finishing after its Session and provider stop.
    drain =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :release -> :ok
           end
         end}
      )

    assert :ok = SessionManager.register_effect_workers(manager, left.pid, left_provider, [drain])

    assert :ok = SessionManager.stop_session(manager, parent_id)
    assert_receive {:DOWN, ^left_monitor, :process, _, _}, @timeout
    assert_receive {:DOWN, ^provider_monitor, :process, ^left_provider, _}, @timeout
    assert File.dir?(left.project_root)
    draft = draft |> Composer.edit(target, {:insert, "unsent"}) |> Composer.submit(target)

    assert_receive {:subagent_peek_sent, ^left_identity, token, {:error, :subagent_unavailable}},
                   @timeout

    draft = Composer.sent(draft, left_identity, token, {:error, :subagent_unavailable})

    assert {"unsent", {0, 6}, false, "This subagent is no longer available. Draft kept."} =
             Composer.presentation(draft.agent_connection.peek_composer, left_identity)

    send(drain, :release)
    assert_disposal(left.identity, :removed)

    assert %{outcome: {:preserved, path, "subagent/" <> _, :changed}} =
             assert_disposal(right.identity)

    assert path == right.project_root
    refute File.exists?(left.project_root)
    assert File.read!(file) == "keep this work"
    assert Path.expand(right.project_root) in git_worktrees(ctx.root)
  end

  test "cancelled setup keeps its reserved slot until the allocated worktree is disposed", ctx do
    gate = make_ref()

    manager =
      start_manager(ctx,
        foreground_subagent_limit: 1,
        foreground_worktree_opts: [
          backend: SubagentWorktreeBackend,
          backend_opts: [root: ctx.root, test_pid: self(), setup_gate: gate]
        ]
      )

    {parent_id, parent} = start_parent(ctx, manager, ["cancel"])
    assert :ok = Session.send_prompt(parent, "cancel during setup")
    assert_receive {:worktree_allocated, setup_pid, ^gate, path}, @timeout
    on_exit(fn -> send(setup_pid, {gate, :continue}) end)
    assert File.dir?(path)
    assert :ok = Session.abort(parent)

    {_other_id, other} = start_parent(ctx, manager, ["at-capacity"])
    assert :ok = Session.send_prompt(other, "try another while setup is still allocated")

    assert_receive {:agent_event, ^other,
                    {:tool_ended, %Event.ToolEnd{tool_call_id: "at-capacity", result: result}}},
                   @timeout

    assert result =~ "foreground_subagent_capacity"
    send(setup_pid, {gate, :continue})

    assert_receive {:minga_event, :foreground_subagent_disposed,
                    %{identity: {^parent_id, {_, _, "cancel"}} = identity, outcome: :removed}},
                   @timeout

    refute File.exists?(path)
    assert {:error, :subagent_unavailable} = SessionManager.foreground_subagent(manager, identity)
    refute_receive {:minga_event, :foreground_subagent_changed, %{identity: ^identity}}, 0
    refute_receive {:child_request, _, @brief}, 0
  end

  test "reports a checkout when Git fails after creating it", ctx do
    manager =
      start_manager(ctx,
        foreground_worktree_opts: [
          backend: SubagentWorktreeBackend,
          backend_opts: [root: ctx.root, test_pid: self(), partial_setup: true]
        ]
      )

    {parent_id, parent} = start_parent(ctx, manager, ["partial"])
    assert :ok = Session.send_prompt(parent, "start the isolated child")

    assert_receive {:worktree_command, _, ["worktree", "add", "-b", branch, path, _]}, @timeout

    assert_receive {:minga_event, :foreground_subagent_disposed,
                    %{
                      identity: {^parent_id, {_, _, "partial"}},
                      outcome: {:preserved, ^path, ^branch, {:uncertain, _}}
                    }},
                   @timeout

    assert_receive {:agent_event, ^parent,
                    {:tool_ended, %Event.ToolEnd{tool_call_id: "partial", result: result}}},
                   @timeout

    assert result =~ path
    assert result =~ branch
    assert File.read!(Path.join(path, "hook-output.txt")) == "written before index setup failed"
  end

  test "the isolated checkout remains while an independent background child still uses it", ctx do
    manager =
      start_manager(ctx,
        foreground_worktree_opts: [
          backend: SubagentWorktreeBackend,
          backend_opts: [root: ctx.root, test_pid: self()]
        ]
      )

    Events.subscribe(:agent_session_stopped)
    {parent_id, parent} = start_parent(ctx, manager, ["isolated"])
    assert :ok = Session.send_prompt(parent, "start the isolated child")
    child = await_child(parent_id, "isolated")
    assert_receive {:child_request, turn, @brief}, @timeout
    send(turn, {:answer, "initial result"})
    assert_parent_result(parent, child, "initial result")
    hook_owner_path = Path.join(Path.dirname(child.project_root), "hook-owner.pid")
    File.write!(hook_owner_path, inspect(self()))

    hook = %{
      event: :session_start,
      type: :module,
      module: __MODULE__,
      function: :write_after_checkout_owners_stop
    }

    assert {:ok, [^hook]} = Options.set(ctx.options, :agent_hooks, [hook])

    provider_opts =
      Keyword.merge(ctx.provider_opts,
        project_root: child.project_root,
        llm_client: fn model, _, _ -> stream(model, [StreamChunk.text("started")], :stop) end
      )

    assert {:ok, background} =
             SessionManager.start_background_subagent(
               manager,
               child.pid,
               "continue independently",
               session_opts: [
                 provider: Native,
                 provider_opts: provider_opts,
                 persist?: false,
                 options_server: ctx.options
               ]
             )

    assert_receive {:checkout_hook_started, hook_pid}, @timeout
    on_exit(fn -> send(hook_pid, :write_draft) end)

    child_id = child.session_id
    assert :ok == SessionManager.stop_session(manager, child_id)

    assert_receive {:minga_event, :agent_session_stopped, %{session_id: ^child_id}}, @timeout

    assert {:ok, background.pid} == SessionManager.get_session(manager, background.session_id)
    assert File.dir?(child.project_root)

    background_id = background.session_id
    assert :ok == SessionManager.stop_session(manager, background_id)
    assert_receive {:minga_event, :agent_session_stopped, %{session_id: ^background_id}}, @timeout
    assert {:error, :not_found} = SessionManager.get_session(manager, background_id)
    assert File.dir?(child.project_root)
    send(hook_pid, :write_draft)

    root = child.project_root

    assert %{outcome: {:preserved, ^root, "subagent/" <> _, :changed}} =
             assert_disposal(child.identity)

    assert File.read!(Path.join(root, "late-hook-draft.txt")) == "written by startup hook"
  end

  @doc false
  @spec write_after_checkout_owners_stop(map()) :: :allow
  def write_after_checkout_owners_stop(%{"project_root" => root}) do
    "#PID" <> pid = File.read!(Path.join(Path.dirname(root), "hook-owner.pid"))
    owner = pid |> String.to_charlist() |> :erlang.list_to_pid()
    send(owner, {:checkout_hook_started, self()})

    receive do
      :write_draft ->
        File.write!(Path.join(root, "late-hook-draft.txt"), "written by startup hook")
    after
      @timeout -> :ok
    end

    :allow
  end

  test "a new Session cannot enter a checkout once removal starts", ctx do
    gate = make_ref()

    manager =
      start_manager(ctx,
        foreground_worktree_opts: [
          backend: SubagentWorktreeBackend,
          backend_opts: [root: ctx.root, test_pid: self(), disposal_gate: gate]
        ]
      )

    {parent_id, parent} = start_parent(ctx, manager, ["disposing"])
    assert :ok = Session.send_prompt(parent, "begin work")
    child = await_child(parent_id, "disposing")
    assert_receive {:child_request, turn, @brief}, @timeout
    send(turn, {:answer, "initial result"})
    assert_parent_result(parent, child, "initial result")
    assert :ok = SessionManager.stop_session(manager, child.session_id)

    root = child.project_root
    assert_receive {:worktree_disposing, worker, ^gate, ^root}, @timeout
    on_exit(fn -> send(worker, {gate, :continue}) end)

    assert {:ok, view} = MingaAgent.ProjectView.direct(root)

    for location <- [[project_root: root], [project_view: view]] do
      assert {:error, :checkout_disposing} =
               SessionManager.start_session(manager,
                 provider: Native,
                 persist?: false,
                 provider_opts: Keyword.merge(ctx.provider_opts, location)
               )
    end

    send(worker, {gate, :continue})
    assert_disposal(child.identity, :removed)
  end

  test "an unrelated provider warning does not settle the child's first report", ctx do
    manager = start_manager(ctx)
    {parent_id, parent} = start_parent(ctx, manager, ["advisory"], false)
    assert :ok = Session.send_prompt(parent, "fan out")
    child = await_child(parent_id, "advisory")
    assert_receive {:child_request, turn, @brief}, @timeout

    notice = "MCP server optional stopped. Built-in tools remain available."
    send(child.pid, {:agent_provider_lifecycle_event, %Event.Error{message: notice}})
    assert {:system, notice, :error} in Session.messages(child.pid)

    assert {:ok, %{writable?: false}} =
             SessionManager.foreground_subagent(manager, child.identity)

    assert [%ToolCall{status: :running}] = parent_results(parent)

    send(turn, {:answer, "actual initial result"})
    assert_parent_result(parent, child, "actual initial result")
    assert [%ToolCall{result: "actual initial result"}] = parent_results(parent)
  end

  test "the initial deadline refuses the waiter and disposes worktree setup when it returns",
       ctx do
    gate = make_ref()

    manager =
      start_manager(ctx,
        foreground_timeout_ms: 500,
        foreground_worktree_opts: [
          backend: SubagentWorktreeBackend,
          backend_opts: [root: ctx.root, test_pid: self(), setup_gate: gate]
        ]
      )

    {parent_id, parent} = start_parent(ctx, manager, ["deadline-call"])
    forged = {parent_id, {"fake-request", "fake-checkpoint", "deadline-call"}}

    assert {:error, :subagent_owner_unavailable} =
             SessionManager.admit_foreground_subagent(
               manager,
               forged,
               {self(), make_ref()},
               @brief,
               [],
               project_root: ctx.root,
               isolated?: true,
               timeout: 200
             )

    refute_receive {:worktree_command, _, ["worktree", "add" | _]}, 0
    assert :ok = Session.send_prompt(parent, "begin an admitted tool")

    assert_receive {:agent_event, ^parent,
                    {:tool_started,
                     %Event.ToolStart{tool_call_id: "deadline-call", invocation_key: key}}},
                   @timeout

    identity = {parent_id, key}

    assert_receive {:worktree_allocated, setup_pid, ^gate, path}, @timeout
    on_exit(fn -> send(setup_pid, {gate, :continue}) end)

    assert_receive {:agent_event, ^parent,
                    {:tool_ended, %Event.ToolEnd{tool_call_id: "deadline-call", result: result}}},
                   @timeout

    assert result =~ "initial_request_timeout"
    assert File.dir?(path)
    assert {:ok, ^parent} = SessionManager.get_session(manager, parent_id)
    send(setup_pid, {gate, :continue})

    assert_disposal(identity, :removed)
    refute File.exists?(path)
    refute_receive {:minga_event, :foreground_subagent_changed, %{identity: ^identity}}, 0
  end

  test "explicit child stop leaves its parent and sibling live, then parent rekey retires the sibling",
       ctx do
    manager = start_manager(ctx)
    {parent_id, parent} = start_parent(ctx, manager, ["stopped", "kept"], false)
    assert :ok = Session.send_prompt(parent, "fan out")
    stopped = await_child(parent_id, "stopped")
    assert_receive {:child_request, turn, @brief}, @timeout
    send(turn, {:answer, "immutable report"})
    assert_parent_result(parent, stopped, "immutable report")
    kept = await_child(parent_id, "kept")
    assert_receive {:child_request, turn, @brief}, @timeout

    assert :ok = SessionManager.stop_session(manager, stopped.session_id)
    assert_disposal(stopped.identity, :no_worktree)
    assert {:ok, ^kept} = SessionManager.foreground_subagent(manager, kept.identity)
    assert {:ok, ^parent} = SessionManager.get_session(manager, parent_id)
    send(turn, {:answer, "another report"})
    assert_parent_result(parent, kept, "another report")
    assert_receive {:agent_event, ^parent, {:status_changed, :idle}}, @timeout

    assert [%ToolCall{result: "immutable report"}, %ToolCall{result: "another report"}] =
             parent_results(parent)

    assert :ok = Session.new_session(parent)
    refute Session.session_id(parent) == parent_id
    assert_disposal(kept.identity, :no_worktree)

    assert {:error, :subagent_unavailable} =
             SessionManager.foreground_subagent(manager, kept.identity)
  end

  test "the child stays read-only while PostToolUse holds the uncommitted report", ctx do
    manager = start_manager(ctx)

    hook = %Hook{
      event: :post_tool_use,
      type: :module,
      tool_pattern: "subagent",
      module: __MODULE__,
      function: :hold_parent_result
    }

    {parent_id, parent} =
      start_parent(ctx, manager, ["blocked-report"], false,
        config: %AgentConfig{agent_hooks: [hook]}
      )

    assert :ok = Session.send_prompt(parent, "fan out")
    child = await_child(parent_id, "blocked-report")
    assert_receive {:child_request, turn, @brief}, @timeout
    send(turn, {:answer, inspect(self())})
    assert_receive {:holding_report, hook_pid}, @timeout
    on_exit(fn -> send(hook_pid, :release_report) end)

    assert {:ok, %{writable?: false}} =
             SessionManager.foreground_subagent(manager, child.identity)

    assert [%ToolCall{status: :running, result: ""}] = parent_results(parent)
    assert :ok = Session.abort(parent)
    send(hook_pid, :release_report)
    assert_disposal(child.identity, :no_worktree)

    assert {:error, :subagent_unavailable} =
             SessionManager.foreground_subagent(manager, child.identity)
  end

  @doc false
  @spec hold_parent_result(map()) :: :allow
  def hold_parent_result(%{"result" => "#PID" <> pid}) do
    owner = pid |> String.to_charlist() |> :erlang.list_to_pid()
    send(owner, {:holding_report, self()})

    receive do
      :release_report -> :allow
    after
      @timeout -> :allow
    end
  end

  test "a failed child retains its partial transcript without revising the parent's report",
       ctx do
    manager = start_manager(ctx)
    {parent_id, parent} = start_parent(ctx, manager, ["broken-stream"], false)
    assert :ok = Session.send_prompt(parent, "fan out")

    child = await_child(parent_id, "broken-stream")
    assert_receive {:child_request, turn, @brief}, @timeout
    send(turn, {:interrupt, "partial review findings"})
    assert_parent_result(parent, child, "Agent response ended before a continuation was returned")
    assert_receive {:agent_event, ^parent, {:status_changed, :idle}}, @timeout
    assert {:ok, %{writable?: true}} = SessionManager.foreground_subagent(manager, child.identity)
    assert inspect(Session.messages(child.pid)) =~ "partial review findings"
    assert [%ToolCall{result: failure}] = parent_results(parent)

    assert :ok =
             SessionManager.send_foreground_subagent_prompt(manager, child.identity, "try again")

    assert_receive {:child_request, turn, "try again"}, @timeout
    send(turn, {:answer, "second attempt"})
    assert [%ToolCall{result: ^failure}] = parent_results(parent)
  end

  defp start_manager(ctx, extra_opts \\ []) do
    owner = self()

    child_client = fn model, messages, _opts ->
      %{content: content} = messages |> Enum.reverse() |> Enum.find(&(&1.role == :user))
      prompt = for %{type: :text, text: text} <- content, into: "", do: text
      send(owner, {:child_request, self(), prompt})

      receive do
        {:answer, answer} ->
          stream(model, [StreamChunk.text(answer)], :stop)

        {:interrupt, partial} ->
          broken =
            Stream.resource(
              fn -> :first end,
              fn
                :first -> {[StreamChunk.text(partial)], :broken}
                :broken -> raise "connection reset"
              end,
              fn _ -> :ok end
            )

          stream_response(model, broken)
      after
        @timeout -> raise "test did not release child transport"
      end
    end

    opts = [
      name: :"foreground_manager_#{ctx.suffix}",
      session_supervisor: ctx.supervisor,
      foreground_provider_opts: Keyword.put(ctx.provider_opts, :llm_client, child_client)
    ]

    start_supervised!({SessionManager, opts ++ extra_opts})
  end

  defp start_parent(ctx, manager, calls, isolated? \\ true, provider_overrides \\ []) do
    args =
      if isolated?, do: %{"task" => @brief, "isolation" => "worktree"}, else: %{"task" => @brief}

    parent_client = fn model, messages, _opts ->
      if List.last(messages).role == :user do
        chunks = Enum.map(calls, &StreamChunk.tool_call("subagent", args, %{id: &1}))
        stream(model, chunks, :tool_use)
      else
        stream(model, [StreamChunk.text("parent done")], :stop)
      end
    end

    assert {:ok, id, parent} =
             SessionManager.start_session(manager,
               provider: Native,
               model_name: @model,
               persist?: false,
               options_server: ctx.options,
               hooks_enabled?: false,
               provider_opts:
                 ctx.provider_opts
                 |> Keyword.merge(project_root: ctx.root, llm_client: parent_client)
                 |> Keyword.merge(provider_overrides)
             )

    assert :ok = Session.subscribe(parent)
    assert is_pid(Session.get_provider(parent))
    {id, parent}
  end

  defp await_child(parent_id, call_id) do
    assert_receive {:minga_event, :foreground_subagent_changed,
                    %{identity: {^parent_id, {_, _, ^call_id}}, brief: @brief, writable?: false} =
                      child},
                   @timeout

    child
  end

  defp assert_parent_result(parent, %{identity: {_, key}}, prefix) do
    assert_receive {:agent_event, ^parent,
                    {:tool_ended,
                     %Event.ToolEnd{name: "subagent", invocation_key: ^key, result: text}}},
                   @timeout

    assert String.starts_with?(text, prefix)
  end

  defp assert_disposal(identity) do
    assert_receive {:minga_event, :foreground_subagent_disposed,
                    %{identity: ^identity} = disposal},
                   @timeout

    disposal
  end

  defp assert_disposal(identity, outcome),
    do: assert(%{outcome: ^outcome} = assert_disposal(identity))

  defp parent_results(session) do
    for {:tool_call, %ToolCall{name: "subagent"} = call} <- Session.messages(session), do: call
  end

  defp child_root(child), do: Session.subagent_context(child.pid).project_root

  defp composer_for(manager, identity) do
    peek = Window.new_subagent_peek(2, {1, identity}, Viewport.new(24, 80))
    windows = Windows.new(WindowTree.new(2), 2, 3, %{2 => peek})
    target = {peek.id, identity}

    state = %EditorState{
      workspace: Workspace.set_windows(%Workspace{}, windows),
      agent_connection: %AgentConnection{session_manager: manager}
    }

    {Composer.focus(state, target), target}
  end

  defp git_worktrees(root) do
    root
    |> git!(["worktree", "list", "--porcelain"])
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn
      "worktree " <> path -> [path]
      _ -> []
    end)
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  defp stream(model, chunks, finish_reason) do
    stream_response(model, chunks ++ [StreamChunk.meta(%{finish_reason: finish_reason})])
  end

  defp stream_response(model, chunks) do
    {:ok, handle} = MetadataHandle.start_link(fn -> %{usage: %{}, finish_reason: :stop} end)

    {:ok,
     %ReqLLM.StreamResponse{
       stream: chunks,
       metadata_handle: handle,
       cancel: fn -> :ok end,
       model: model,
       context: ReqLLM.Context.new()
     }}
  end
end
