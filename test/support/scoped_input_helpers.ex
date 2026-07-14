defmodule Minga.Test.ScopedInputHelpers do
  @moduledoc false

  import ExUnit.Assertions

  alias MingaEditor.Agent.UIState
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Input.Scoped
  alias Minga.Mode
  alias Minga.Project.FileTree
  alias Minga.Project.FileTree.BufferSync
  alias Minga.Test.StubServer

  @type handler_result :: {:handled | :passthrough, EditorState.t()}

  @spec base_state(keyword()) :: EditorState.t()
  def base_state(opts) do
    opts = Keyword.put_new_lazy(opts, :sidebar_registry, fn -> private_sidebar_registry() end)
    {:ok, buf} = BufferProcess.start_link(content: "hello world")
    {:ok, prompt_buf} = BufferProcess.start_link(content: "")

    agent = %AgentState{}

    agentic = %UIState{
      panel: %UIState.Panel{
        visible: Keyword.get(opts, :panel_visible, false),
        input_focused: Keyword.get(opts, :input_focused, false),
        prompt_buffer: prompt_buf
      }
    }

    agentic =
      if Keyword.get(opts, :agentic_active, false) do
        agentic
        |> UIState.activate(nil, nil)
        |> UIState.set_focus(Keyword.get(opts, :focus, :chat))
      else
        agentic
      end

    tab_bar =
      if Keyword.get(opts, :agentic_active, false) do
        # Agent mode: file tab + agent tab, agent tab active
        tb = TabBar.new(Tab.new_file(1, "[no file]"))
        {tb, _} = TabBar.add(tb, :agent, "Agent")
        tb
      else
        TabBar.new(Tab.new_file(1, "[no file]"))
      end

    mode = if(Keyword.get(opts, :input_focused, false), do: :insert, else: :normal)

    %EditorState{
      port_manager: self(),
      sidebar_registry: Keyword.fetch!(opts, :sidebar_registry),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: %VimState{mode: mode, mode_state: Mode.initial_state()},
        buffers: %Buffers{active: buf, list: [buf]},
        keymap_scope: Keyword.get(opts, :keymap_scope, :editor),
        agent_ui: agentic
      },
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          %TraditionalState{}
          |> TraditionalState.replace_agent(agent)
          |> TraditionalState.set_tab_bar(tab_bar)
        )
    }
  end

  @spec activated_agent_state() :: {EditorState.t(), pid(), pid()}
  def activated_agent_state do
    state = base_state(keymap_scope: :editor, agentic_active: false)
    file_buffer = state.workspace.buffers.active
    {:ok, session} = StubServer.start_link()

    return_target =
      UIState.return_target(
        1,
        file_buffer,
        state.workspace.windows,
        EditorState.file_tree_state(state),
        :editor,
        false
      )

    agent_ui =
      UIState.activate(
        state.workspace.agent_ui,
        state.workspace.windows,
        EditorState.file_tree_state(state),
        return_target
      )

    {tab_bar, agent_tab} = TabBar.add(state.shell_runtime.state.tab_bar, :agent, "Agent")
    {tab_bar, workspace} = TabBar.add_workspace(tab_bar, "Agent", session)
    workspace = Workspace.set_agent_ui(workspace, agent_ui)

    tab_bar =
      tab_bar
      |> TabBar.update_workspace(workspace.id, fn _ -> workspace end)
      |> TabBar.update_tab(agent_tab.id, fn tab ->
        tab |> Tab.set_session(session) |> Tab.set_group(workspace.id)
      end)

    workspace_state = %{state.workspace | agent_ui: agent_ui, keymap_scope: :agent}

    state =
      state
      |> EditorState.set_tab_bar(tab_bar)
      |> EditorState.set_workspace(workspace_state)

    {state, session, file_buffer}
  end

  @spec focus_prompt(EditorState.t(), String.t()) :: EditorState.t()
  def focus_prompt(state, text) do
    AgentAccess.update_agent_ui(state, fn ui ->
      ui
      |> UIState.set_input_focused(true)
      |> UIState.set_prompt_text(text)
    end)
  end

  @spec assert_passthrough_then_handled(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          handler_result()
  def assert_passthrough_then_handled(state, cp, mods) do
    assert {:passthrough, _} = Scoped.handle_key(state, cp, mods)
    assert {:handled, _} = walk_surface_handlers(state, cp, mods)
  end

  @doc false
  @spec walk_surface_handlers(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          handler_result()
  def walk_surface_handlers(state, cp, mods) do
    Enum.reduce_while(MingaEditor.Input.surface_handlers(), {:passthrough, state}, fn handler,
                                                                                      {_, acc} ->
      case handler.handle_key(acc, cp, mods) do
        {:handled, new_state} -> {:halt, {:handled, new_state}}
        {:passthrough, new_state} -> {:cont, {:passthrough, new_state}}
      end
    end)
  end

  @spec ft(EditorState.t()) :: FileTreeState.t()
  def ft(state), do: EditorState.file_tree_state(state)

  @spec walk_surface_mouse(
          EditorState.t(),
          non_neg_integer(),
          non_neg_integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: handler_result()
  def walk_surface_mouse(state, row, col, button, mods, event_type, cc) do
    handlers =
      MingaEditor.Input.surface_handlers()
      |> Enum.filter(&function_exported?(&1, :handle_mouse, 7))

    Enum.reduce_while(handlers, {:passthrough, state}, fn handler, {_, acc} ->
      case handler.handle_mouse(acc, row, col, button, mods, event_type, cc) do
        {:handled, new_state} -> {:halt, {:handled, new_state}}
        {:passthrough, new_state} -> {:cont, {:passthrough, new_state}}
      end
    end)
  end

  @spec make_tree_state(String.t()) :: EditorState.t()
  def make_tree_state(tmp_dir), do: make_tree_state(tmp_dir, 5)

  @spec make_tree_state(String.t(), non_neg_integer()) :: EditorState.t()
  def make_tree_state(tmp_dir, file_count) do
    if file_count > 0 do
      for i <- 1..file_count do
        File.write!(
          Path.join(tmp_dir, "file_#{String.pad_leading(to_string(i), 2, "0")}.txt"),
          ""
        )
      end
    end

    tree = FileTree.new(tmp_dir)
    buf = BufferSync.start_buffer(tree)

    state = base_state(keymap_scope: :file_tree)
    EditorState.set_file_tree(state, %FileTreeState{tree: tree, focused: true, buffer: buf})
  end

  defp private_sidebar_registry do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")

    ExUnit.Callbacks.start_supervised!(
      {MingaEditor.Extension.Sidebar, name: table, notify: false}
    )

    table
  end
end
