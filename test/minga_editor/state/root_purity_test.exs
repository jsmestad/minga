defmodule MingaEditor.State.RootPurityTest do
  # Mutates the global shell registry and Erlang call-trace patterns.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.BufferLifecycle
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Parser, as: ParserState

  @effect_modules [
    Minga.Buffer,
    Minga.Buffer.Process,
    Minga.Log,
    MingaEditor.WorkspaceWorkflow,
    MingaEditor.State.Workspace.Persistence
  ]

  setup do
    Registry.reset_for_test()
    Registry.seed_builtin()

    :ok =
      Registry.register({:extension, :root_purity_shell}, %{
        id: :root_purity_shell,
        module: MingaEditor.Test.FakeShell,
        display_name: "Root Purity Shell",
        description: "Effect probe",
        default?: false,
        capabilities: []
      })

    on_exit(fn ->
      Registry.reset_for_test()
      Registry.seed_builtin()
    end)

    :ok
  end

  @tag :tmp_dir
  test "direct register and remove transitions perform no external work", %{tmp_dir: root} do
    buffer_probe = start_call_probe(:buffer)
    parser_probe = start_call_probe(:parser)
    state = probe_state(buffer_probe, parser_probe, root)
    monitors_before = Process.info(self(), :monitors)

    {{registered, removed}, calls} =
      trace_calls(@effect_modules, fn ->
        {registered, {:monitor, ^buffer_probe}} =
          EditorState.register_buffer(state, buffer_probe, :open)

        removed = EditorState.remove_buffer(registered, buffer_probe)
        {registered, removed}
      end)

    assert registered.workspace.buffers.list == [buffer_probe]
    assert removed.workspace.buffers.list == []
    assert calls == []
    assert Process.info(self(), :monitors) == monitors_before
    refute_receive {:probe_call, :buffer, _request}
    refute_receive {:probe_call, :parser, _request}
    refute_receive {:buffer_added, ^buffer_probe}
    refute_receive {:buffer_died, ^buffer_probe}
    refute File.exists?(Path.join(root, ".minga/workspaces"))
  end

  test "buffer registry owns monitor parser shell logging and persistence workflows" do
    parser_probe = start_call_probe(:parser)
    buffer = start_supervised!({BufferProcess, content: "workflow"})
    state = probe_state(nil, parser_probe, nil)

    {{registered, retired}, calls} =
      trace_calls(@effect_modules, fn ->
        registered = BufferRegistry.add_buffer(state, buffer)
        retired = BufferRegistry.retire_dead_buffer(registered, buffer)
        {registered, retired}
      end)

    assert_receive {:buffer_added, ^buffer}
    assert_receive {:probe_call, :parser, {:unregister_buffer, ^buffer}}
    assert_receive {:buffer_died, ^buffer}
    assert is_reference(registered.buffer_lifecycle.buffer_monitors[buffer])
    refute Map.has_key?(retired.buffer_lifecycle.buffer_monitors, buffer)
    refute {:process, buffer} in elem(Process.info(self(), :monitors), 1)

    assert traced_call?(calls, Minga.Buffer, :file_path)
    assert traced_call?(calls, Minga.Log, :debug)
    assert traced_call?(calls, Minga.Log, :info)
    assert traced_call?(calls, MingaEditor.WorkspaceWorkflow, :persist_changes)
  end

  @spec probe_state(pid() | nil, pid(), String.t() | nil) :: EditorState.t()
  defp probe_state(buffer, parser_probe, root) do
    buffers =
      case buffer do
        pid when is_pid(pid) -> %Buffers{active: nil, list: []}
        nil -> %Buffers{}
      end

    workspace = %SessionState{buffers: buffers, file_tree: %FileTreeState{project_root: root}}

    runtime = Runtime.new(Registry.get(:root_purity_shell), %{effect_probe: self()})

    %EditorState{
      workspace: workspace,
      shell_runtime: runtime,
      parser: ParserState.new(parser_probe),
      buffer_lifecycle: %BufferLifecycle{}
    }
  end

  @spec trace_calls([module()], (-> result)) :: {result, [{module(), atom(), [term()]}]}
        when result: var
  defp trace_calls(modules, fun) do
    Enum.each(modules, fn module ->
      {:module, ^module} = Code.ensure_loaded(module)
      :erlang.trace_pattern({module, :_, :_}, true, [])
    end)

    tracer = spawn_link(fn -> trace_collector([]) end)
    1 = :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      result = fun.()
      1 = :erlang.trace(self(), false, [:call])
      trace_ref = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^trace_ref}
      send(tracer, {:take_calls, self()})
      assert_receive {:traced_calls, calls}
      {result, Enum.reverse(calls)}
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(modules, &:erlang.trace_pattern({&1, :_, :_}, false, []))
      send(tracer, :stop)
    end
  end

  @spec trace_collector([{module(), atom(), [term()]}]) :: no_return()
  defp trace_collector(calls) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        trace_collector([{module, function, args} | calls])

      {:take_calls, owner} ->
        send(owner, {:traced_calls, calls})
        trace_collector([])

      :stop ->
        exit(:normal)
    end
  end

  @spec traced_call?([{module(), atom(), [term()]}], module(), atom()) :: boolean()
  defp traced_call?(calls, module, function) do
    Enum.any?(calls, fn
      {^module, ^function, _args} -> true
      _other -> false
    end)
  end

  @spec start_call_probe(atom()) :: pid()
  defp start_call_probe(name) do
    owner = self()

    spawn_link(fn -> call_probe_loop(owner, name) end)
  end

  @spec call_probe_loop(pid(), atom()) :: no_return()
  defp call_probe_loop(owner, name) do
    receive do
      {:"$gen_call", {caller, tag}, request} ->
        send(owner, {:probe_call, name, request})
        send(caller, {tag, probe_reply(request)})
        call_probe_loop(owner, name)

      _message ->
        call_probe_loop(owner, name)
    end
  end

  @spec probe_reply(term()) :: term()
  defp probe_reply({:unregister_buffer, _buffer}), do: :ok
  defp probe_reply(_request), do: nil
end
