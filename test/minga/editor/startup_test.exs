defmodule Minga.Editor.StartupTest do
  # async: false because the force_editor test mutates Application env,
  # which races with the first test when run concurrently.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.LayoutPreset
  alias Minga.Editor.Startup
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Editor.WindowTree
  alias Minga.Input

  describe "startup_view_state/1" do
    test "returns :agent scope when startup_view is :agent in TUI mode" do
      {scope, agentic} = Startup.startup_view_state(:tui)

      assert scope == :agent
      assert agentic.view.active == true
      assert agentic.view.focus == :chat
    end

    test "returns :editor scope when force_editor flag is set" do
      Application.put_env(:minga, :cli_startup_flags, %{force_editor: true, no_context: false})

      {scope, agentic} = Startup.startup_view_state(:tui)

      assert scope == :editor
      assert agentic.view.active == false
    after
      Application.delete_env(:minga, :cli_startup_flags)
    end

    test "returns :editor scope for native GUI backend" do
      {scope, _agentic} = Startup.startup_view_state(:native_gui)

      assert scope == :editor
    end
  end

  describe "build_initial_window/5" do
    test "agent mode creates a full-screen agent_chat window" do
      {window, update} = Startup.build_initial_window(:agent, 1, self(), 24, 80)

      assert %Window{} = window
      assert Content.agent_chat?(window.content)
      refute Content.buffer?(window.content)
      assert {:agent_buffer, pid} = update
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "editor mode creates a buffer window" do
      {:ok, buf} = BufferServer.start_link(content: "hello")

      {window, update} = Startup.build_initial_window(:editor, 1, buf, 24, 80)

      assert %Window{} = window
      assert Content.buffer?(window.content)
      refute Content.agent_chat?(window.content)
      assert window.buffer == buf
      assert update == :noop
    end

    test "editor mode with nil buffer returns nil window" do
      {window, update} = Startup.build_initial_window(:editor, 1, nil, 24, 80)

      assert window == nil
      assert update == :noop
    end
  end

  describe "startup creates correct window type (integration)" do
    test "agent mode produces has_agent_chat? == true with single-leaf tree" do
      # This is the regression guard. If this test fails, the agent
      # session won't start because AgentLifecycle.maybe_start_session
      # checks LayoutPreset.has_agent_chat? before starting.
      {:ok, buf} = BufferServer.start_link(content: "scratch")

      {window, {:agent_buffer, _agent_buf}} =
        Startup.build_initial_window(:agent, 1, buf, 24, 80)

      # Simulate what build_initial_state does with the window
      state = %EditorState{
        port_manager: self(),
        workspace: %Minga.Workspace.State{
          viewport: Viewport.new(24, 80),
          editing: VimState.new(),
          keymap_scope: :agent,
          windows: %Windows{
            tree: WindowTree.new(1),
            map: %{1 => window},
            active: 1,
            next_id: 2
          }
        },
        focus_stack: Input.default_stack()
      }

      assert LayoutPreset.has_agent_chat?(state),
             "agent startup must produce a state where has_agent_chat? is true"

      assert {:leaf, 1} = state.workspace.windows.tree
      assert map_size(state.workspace.windows.map) == 1
    end

    test "editor mode produces has_agent_chat? == false" do
      {:ok, buf} = BufferServer.start_link(content: "scratch")
      {window, :noop} = Startup.build_initial_window(:editor, 1, buf, 24, 80)

      state = %EditorState{
        port_manager: self(),
        workspace: %Minga.Workspace.State{
          viewport: Viewport.new(24, 80),
          editing: VimState.new(),
          keymap_scope: :editor,
          windows: %Windows{
            tree: WindowTree.new(1),
            map: %{1 => window},
            active: 1,
            next_id: 2
          }
        },
        focus_stack: Input.default_stack()
      }

      refute LayoutPreset.has_agent_chat?(state)
      assert Content.buffer?(state.workspace.windows.map[1].content)
    end
  end
end
