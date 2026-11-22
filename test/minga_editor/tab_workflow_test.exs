defmodule MingaEditor.TabWorkflowTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Parser.Manager
  alias MingaEditor.HighlightSync
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.TabWorkflow
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.WorkspaceWorkflow

  import MingaEditor.RenderPipeline.TestHelpers

  setup do
    name = Module.concat(__MODULE__, "Parser#{System.unique_integer([:positive])}")
    manager = start_supervised!({Manager, name: name, parser_path: "/missing/minga-parser"})
    %{manager: manager}
  end

  test "switch/2 restores parser presentation for an evicted inactive file tab", %{
    manager: manager
  } do
    state = base_state(filetype: :elixir, parser_manager: manager)

    second_buffer =
      start_supervised!({BufferProcess, content: "defmodule Two do\nend\n", filetype: :elixir})

    state = install_two_file_tabs(state, second_buffer)
    tab2 = Enum.find(state.shell_runtime.state.tab_bar.tabs, &(&1.label == "two.ex"))

    state = HighlightSync.setup_for_buffer_pid(state, second_buffer)

    assert is_integer(Manager.buffer_id(second_buffer, manager))
    assert Map.has_key?(state.parser.highlighting.highlights, second_buffer)

    Process.sleep(2)

    evicted = HighlightSync.evict_inactive(state, ttl_ms: 0)

    assert Manager.buffer_id(second_buffer, manager) == nil
    refute Map.has_key?(evicted.parser.highlighting.highlights, second_buffer)
    assert evicted.workspace.buffers.active != second_buffer

    switched = TabWorkflow.switch(evicted, tab2.id)

    assert switched.workspace.buffers.active == second_buffer
    assert is_integer(Manager.buffer_id(second_buffer, manager))
    assert Map.has_key?(switched.parser.highlighting.highlights, second_buffer)
  end

  test "restore_context/2 restores parser presentation for an evicted file context", %{
    manager: manager
  } do
    state = base_state(filetype: :elixir, parser_manager: manager)

    second_buffer =
      start_supervised!(
        {BufferProcess, content: "defmodule Restored do\nend\n", filetype: :elixir}
      )

    state = HighlightSync.setup_for_buffer_pid(state, second_buffer)

    assert is_integer(Manager.buffer_id(second_buffer, manager))
    assert Map.has_key?(state.parser.highlighting.highlights, second_buffer)

    Process.sleep(2)

    evicted = HighlightSync.evict_inactive(state, ttl_ms: 0)

    assert Manager.buffer_id(second_buffer, manager) == nil
    refute Map.has_key?(evicted.parser.highlighting.highlights, second_buffer)

    restored = TabWorkflow.restore_context(evicted, tab_context(second_buffer))

    assert restored.workspace.buffers.active == second_buffer
    assert is_integer(Manager.buffer_id(second_buffer, manager))
    assert Map.has_key?(restored.parser.highlighting.highlights, second_buffer)
  end

  test "arriving at an Agent tab without a session attaches an editable composer", %{
    manager: manager
  } do
    state = base_state(filetype: :elixir, parser_manager: manager)
    tabs = TabBar.new(Tab.new_file(1, "one.ex"))
    {tabs, workspace} = TabBar.add_workspace(tabs, "Agent")
    {tabs, tab} = TabBar.insert(tabs, :agent, "Agent")
    context = Context.new_agent(state.frontend.terminal_viewport, nil)

    tabs =
      tabs
      |> TabBar.move_tab_to_workspace(tab.id, workspace.id)
      |> TabBar.update_context(tab.id, context)

    active = state |> WorkspaceWorkflow.install_tab_bar(tabs) |> TabWorkflow.switch(tab.id)
    assert MingaEditor.Shell.Runtime.active_session(active.shell_runtime) == nil
    prompt = active.workspace.agent_ui.panel.prompt_buffer
    on_exit(fn -> if is_pid(prompt) and Process.alive?(prompt), do: GenServer.stop(prompt) end)
    assert is_pid(prompt)
    :ok = Minga.Buffer.insert_text(prompt, "unfinished draft")

    restored = TabWorkflow.restore_context(active, context)
    assert restored.workspace.agent_ui.panel.prompt_buffer == prompt
    assert Minga.Buffer.content(prompt) == "unfinished draft"

    :ok = GenServer.stop(prompt)
    recovered = TabWorkflow.restore_context(restored, context)
    replacement = recovered.workspace.agent_ui.panel.prompt_buffer

    on_exit(fn ->
      if is_pid(replacement) and Process.alive?(replacement), do: GenServer.stop(replacement)
    end)

    assert replacement != prompt
    assert Minga.Buffer.content(replacement) == ""
  end

  defp install_two_file_tabs(state, second_buffer) do
    tab_bar =
      Tab.new_file(1, "one.ex")
      |> TabBar.new()
      |> TabBar.update_context(1, Context.snapshot(state.workspace))

    {tab_bar, tab2} = TabBar.add(tab_bar, :file, "two.ex")

    tab_bar =
      tab_bar
      |> TabBar.update_context(tab2.id, tab_context(second_buffer))
      |> TabBar.switch_to(1)

    WorkspaceWorkflow.install_tab_bar(state, tab_bar)
  end

  defp tab_context(buffer) do
    win_id = 1
    window = Window.new(win_id, buffer, 24, 80)

    Map.from_struct(%SessionState{
      editing: VimState.new(),
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(win_id),
        map: %{win_id => window},
        active: win_id,
        next_id: win_id + 1
      }
    })
  end
end
