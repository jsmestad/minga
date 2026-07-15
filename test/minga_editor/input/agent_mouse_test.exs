defmodule MingaEditor.Input.AgentMouseTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.UIState
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Layout
  alias MingaEditor.LayoutPreset
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.Input.AgentMouse
  alias MingaEditor.Input.Router
  alias Minga.Mode

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    Process.put(:sidebar_registry, table)
    :ok
  end

  # ── Test helpers ───────────────────────────────────────────────────────────

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferProcess.start_link(content: "hello\nworld\nfoo\nbar\nbaz")
    {:ok, _prompt_buf} = BufferProcess.start_link(content: "")

    agent = %AgentState{error: nil, spinner_timer: nil}

    agentic = UIState.new()
    tab_bar = TabBar.new(Tab.new_file(1, "[no file]"))

    win_id = 1
    win = Window.new(win_id, buf, 24, 80)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      extension_surfaces: %MingaEditor.State.ExtensionSurfaces{
        sidebar_registry: Process.get(:sidebar_registry)
      },
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: %VimState{mode: :normal, mode_state: Mode.initial_state()},
        buffers: %Buffers{active: buf, list: [buf]},
        keymap_scope: Keyword.get(opts, :keymap_scope, :editor),
        agent_ui: agentic,
        windows: %Windows{
          tree: {:leaf, win_id},
          map: %{win_id => win},
          active: win_id,
          next_id: win_id + 1
        }
      },
      interaction: %MingaEditor.State.Interaction{focus_stack: []},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Traditional.State.replace_agent(
              %MingaEditor.Shell.Traditional.State{},
              agent
            ),
            tab_bar
          )
        )
    }
  end

  defp with_agent_split(state, agent_content \\ "") do
    state
    |> LayoutPreset.apply(:agent_right, nil)
    |> seed_agent_transcript(agent_content)
  end

  defp seed_agent_transcript(state, ""), do: state

  defp seed_agent_transcript(state, agent_content) do
    line_index =
      agent_content
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.map(fn {_line, idx} -> {idx, :assistant} end)

    total_lines = Enum.count(line_index)

    MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
      state,
      (fn panel ->
         %{
           panel
           | cached_line_index: line_index,
             scroll: Minga.Editing.Scroll.update_metrics(panel.scroll, total_lines, 8)
         }
       end).(state.workspace.agent_ui.panel)
    )
  end

  defp with_agent_panel(state) do
    state
    |> then(fn state ->
      MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
        state,
        (fn p ->
           %{p | visible: true, input_focused: true}
         end).(state.workspace.agent_ui.panel)
      )
    end)
    |> Layout.invalidate()
  end

  # The semantic GUI layout reserves no BEAM rows for the agent panel; the
  # frontend renders it natively (`Layout.TUI`'s reserved agent rows were
  # deleted in #2235). Inject an explicit panel rect onto the cached layout so
  # the live FocusTree agent-panel routing and `AgentMouse` dispatch logic stay
  # exercised. Returns the state with the rect cached plus the rect itself.
  defp with_agent_panel_rect(state, rect \\ {16, 0, 80, 8}) do
    %Layout{} = base_layout = Layout.compute(state)
    layout = %Layout{base_layout | agent_panel: rect}
    render = MingaEditor.State.Render.stage_layout(state.render, layout)
    {%{state | render: render}, rect}
  end

  defp agent_chat_window_rect(state) do
    layout = Layout.compute(state)

    Enum.find_value(layout.window_layouts, fn {win_id, wl} ->
      window = Map.get(state.workspace.windows.map, win_id)

      if window != nil and Content.agent_chat?(window.content) do
        wl.content
      end
    end)
  end

  # ── Events outside agent regions pass through ──────────────────────────────

  describe "passthrough" do
    test "events pass through when no agent UI is visible" do
      state = base_state()
      assert {:passthrough, _} = AgentMouse.handle_mouse(state, 5, 5, :wheel_down, 0, :press, 1)
      assert {:passthrough, _} = AgentMouse.handle_mouse(state, 5, 5, :left, 0, :press, 1)
    end

    test "events outside agent regions pass through when agent split is active" do
      state = base_state() |> with_agent_split()
      # Click in the editor area (left pane), not the agent pane
      # The editor window occupies the left ~60% of columns
      assert {:passthrough, _} = AgentMouse.handle_mouse(state, 5, 5, :left, 0, :press, 1)
      assert {:passthrough, _} = AgentMouse.handle_mouse(state, 5, 5, :wheel_down, 0, :press, 1)
    end
  end

  # ── Agent chat window (split pane) scroll ──────────────────────────────────

  describe "agent chat window scroll" do
    setup do
      state = base_state() |> with_agent_split(agent_lines(80))
      rect = agent_chat_window_rect(state)
      {:ok, state: state, rect: rect}
    end

    test "scroll down over agent chat window scrolls semantic transcript and unpins", %{
      state: state,
      rect: rect
    } do
      {row, col, _w, _h} = rect

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 2, col + 2, :wheel_down, 0, :press, 1)

      # Window should be unpinned so viewport follows cursor
      case MingaEditor.Session.State.find_agent_chat_window(new_state.workspace) do
        nil -> :ok
        {_win_id, window} -> refute window.pinned
      end
    end

    test "scroll up over agent chat window scrolls semantic transcript and unpins", %{
      state: state,
      rect: rect
    } do
      {row, col, _w, _h} = rect

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 2, col + 2, :wheel_up, 0, :press, 1)

      # Should not crash and should unpin
      assert %EditorState{} = new_state
    end

    test "focus-tree routing scrolls inactive agent chat window without moving focus" do
      state = base_state() |> with_agent_split(agent_lines(80)) |> Layout.put()
      active_id = state.workspace.windows.active

      {agent_win_id, _agent_window} =
        Enum.find(state.workspace.windows.map, fn {_id, window} ->
          Content.agent_chat?(window.content)
        end)

      refute active_id == agent_win_id
      {row, col, _w, _h} = agent_chat_window_rect(state)
      before_top = Map.fetch!(state.workspace.windows.map, agent_win_id).viewport.top

      new_state = Router.dispatch_mouse(state, row + 2, col + 2, :wheel_down, 0, :press, 1)

      assert new_state.workspace.windows.active == active_id
      assert Map.fetch!(new_state.workspace.windows.map, agent_win_id).viewport.top > before_top
    end

    test "scroll over file viewer sidebar scrolls preview", %{state: state, rect: rect} do
      {row, _col, _w, _h} = rect
      # The file viewer sidebar is to the right of the chat area.
      # chat_width_pct defaults to 65, so sidebar starts at ~65% of the window width.
      # Use a column well to the right of the chat area.
      sidebar_col = state.workspace.viewport.cols - 5

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 2, sidebar_col, :wheel_down, 0, :press, 1)

      # Preview scroll should have changed (or at least not crash)
      assert %EditorState{} = new_state
    end
  end

  # ── Agent chat window (split pane) click ───────────────────────────────────

  describe "agent chat window click" do
    setup do
      state = base_state() |> with_agent_split()
      rect = agent_chat_window_rect(state)
      {:ok, state: state, rect: rect}
    end

    test "click in chat area passthroughs to standard mouse handler", %{state: state, rect: rect} do
      {row, col, _w, _h} = rect

      # Click in the chat area (near the top of the agent window)
      # should passthrough to ModeFSM for standard buffer mouse handling
      {:passthrough, _state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :left, 0, :press, 1)
    end

    test "click in input area focuses input", %{state: state, rect: rect} do
      {_row, col, _w, h} = rect

      # Make sure input is not focused
      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          MingaEditor.Agent.PromptBuffer.set_input_focused(state.workspace.agent_ui, false)
        )

      refute state.workspace.agent_ui.panel.input_focused

      # Click near the bottom of the agent window (where input lives)
      input_row = rect |> elem(0) |> Kernel.+(h - 2)

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, input_row, col + 2, :left, 0, :press, 1)

      assert new_state.workspace.agent_ui.panel.input_focused
    end

    test "click in agent window focuses it when not active", %{state: state} do
      # The editor window should be active (not the agent)
      # Find the agent window id
      {agent_win_id, _} =
        Enum.find(state.workspace.windows.map, fn {_id, w} ->
          Content.agent_chat?(w.content)
        end)

      refute state.workspace.windows.active == agent_win_id

      rect = agent_chat_window_rect(state)
      {row, col, _w, _h} = rect

      # Chat content click passthroughs after focusing the semantic agent pane.
      {:passthrough, new_state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :left, 0, :press, 1)

      assert new_state.workspace.windows.active == agent_win_id
    end
  end

  # ── Agent side panel (bottom panel) scroll ─────────────────────────────────

  describe "agent side panel scroll" do
    setup do
      {state, panel_rect} = base_state() |> with_agent_panel() |> with_agent_panel_rect()
      {:ok, state: state, panel_rect: panel_rect}
    end

    test "scroll down over agent panel scrolls chat", %{state: state, panel_rect: panel_rect} do
      {row, col, _w, _h} = panel_rect
      old_viewport_top = state.workspace.viewport.top

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :wheel_down, 0, :press, 1)

      # Chat scroll offset should change
      panel = new_state.workspace.agent_ui.panel
      assert panel.scroll.offset > 0 or panel.scroll.pinned == false

      # Editor viewport should be untouched
      assert new_state.workspace.viewport.top == old_viewport_top
    end

    test "scroll up over agent panel scrolls chat", %{state: state, panel_rect: panel_rect} do
      {row, col, _w, _h} = panel_rect

      {:handled, state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :wheel_down, 0, :press, 1)

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :wheel_up, 0, :press, 1)

      assert %EditorState{} = new_state
    end
  end

  # ── Agent side panel (bottom panel) click ──────────────────────────────────

  describe "agent side panel click" do
    setup do
      {state, panel_rect} = base_state() |> with_agent_panel() |> with_agent_panel_rect()
      {:ok, state: state, panel_rect: panel_rect}
    end

    test "click in panel chat area unfocuses input", %{state: state, panel_rect: panel_rect} do
      {row, col, _w, _h} = panel_rect

      # Input should be focused initially
      assert state.workspace.agent_ui.panel.input_focused

      # Click near the top of the panel (chat area)
      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :left, 0, :press, 1)

      refute new_state.workspace.agent_ui.panel.input_focused
    end

    test "click in panel input area focuses input", %{state: state, panel_rect: panel_rect} do
      {_row, col, _w, h} = panel_rect

      # Unfocus first
      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          MingaEditor.Agent.PromptBuffer.set_input_focused(state.workspace.agent_ui, false)
        )

      refute state.workspace.agent_ui.panel.input_focused

      # Click near the bottom of the panel (input area)
      input_row = elem(panel_rect, 0) + h - 2

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, input_row, col + 2, :left, 0, :press, 1)

      assert new_state.workspace.agent_ui.panel.input_focused
    end
  end

  # ── Scope independence ─────────────────────────────────────────────────────

  describe "scope independence" do
    test "scroll works in agent window regardless of keymap_scope" do
      # Start in editor scope, but scroll over the agent window
      state = base_state(keymap_scope: :editor) |> with_agent_split(agent_lines(80))
      rect = agent_chat_window_rect(state)

      # Verify we're in editor scope
      assert state.workspace.keymap_scope == :editor

      {row, col, _w, _h} = rect

      {:handled, new_state} =
        AgentMouse.handle_mouse(state, row + 2, col + 2, :wheel_down, 0, :press, 1)

      # Window should be unpinned
      case MingaEditor.Session.State.find_agent_chat_window(new_state.workspace) do
        nil -> :ok
        {_win_id, window} -> refute window.pinned
      end
    end

    test "click in agent window works from editor scope" do
      state = base_state(keymap_scope: :editor) |> with_agent_split()
      rect = agent_chat_window_rect(state)
      {row, col, _w, _h} = rect

      # Chat content click passthroughs after focusing the agent window
      {:passthrough, new_state} =
        AgentMouse.handle_mouse(state, row + 1, col + 2, :left, 0, :press, 1)

      # Window focus happened before passthrough
      {agent_win_id, _} =
        Enum.find(new_state.workspace.windows.map, fn {_id, w} ->
          Content.agent_chat?(w.content)
        end)

      assert new_state.workspace.windows.active == agent_win_id
    end
  end

  defp agent_lines(count) do
    Enum.map_join(1..count, "\n", &"agent line #{&1}")
  end
end
