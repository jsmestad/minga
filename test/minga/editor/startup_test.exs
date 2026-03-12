defmodule Minga.Editor.StartupTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.LayoutPreset
  alias Minga.Editor.Startup
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Editor.WindowTree
  alias Minga.Input
  alias Minga.Mode
  alias Minga.Port.Manager, as: PortManager

  describe "startup_view_state/2" do
    test "returns :agent scope with real window tree when startup_view is :agent" do
      # TUI mode (PortManager atom) with default flags -> agent mode
      {scope, agentic, tree} = Startup.startup_view_state(PortManager, 1)

      assert scope == :agent
      assert agentic.active == true
      assert agentic.focus == :chat
      assert tree == WindowTree.new(1)
    end

    test "returns :editor scope when force_editor flag is set" do
      Application.put_env(:minga, :cli_startup_flags, %{force_editor: true, no_context: false})

      {scope, agentic, tree} = Startup.startup_view_state(PortManager, 1)

      assert scope == :editor
      assert agentic.active == false
      assert tree == WindowTree.new(1)
    after
      Application.delete_env(:minga, :cli_startup_flags)
    end

    test "returns :editor scope in headless mode (non-atom port_manager)" do
      {scope, _agentic, tree} = Startup.startup_view_state(self(), 1)

      assert scope == :editor
      assert tree == WindowTree.new(1)
    end
  end

  describe "maybe_apply_agent_split/1 (the regression guard)" do
    test "creates agent chat window in window tree when keymap_scope is :agent" do
      # Build a minimal state that looks like what build_initial_state produces
      # in agent mode: keymap_scope :agent, a scratch buffer window, real tree.
      {:ok, scratch} = BufferServer.start_link(content: "scratch")
      window = Window.new(1, scratch, 24, 80)

      state = %EditorState{
        port_manager: self(),
        viewport: Viewport.new(24, 80),
        mode: :normal,
        mode_state: Mode.initial_state(),
        keymap_scope: :agent,
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => window},
          active: 1,
          next_id: 2
        },
        focus_stack: Input.default_stack()
      }

      result = Startup.maybe_apply_agent_split(state)

      # The agent split must be applied: has_agent_chat? is the check that
      # AgentLifecycle.maybe_start_session uses to decide whether to start
      # the agent session. If this is false, the agent never boots.
      assert LayoutPreset.has_agent_chat?(result),
             "agent startup must create an agent_chat window so the session can start"

      # The window tree should be a split (scratch left, agent right)
      assert {:split, :vertical, {:leaf, 1}, {:leaf, 2}, _} = result.windows.tree

      # The new window should have agent_chat content
      agent_window = result.windows.map[2]
      assert Content.agent_chat?(agent_window.content)

      # The original scratch window should still be a buffer
      assert Content.buffer?(result.windows.map[1].content)

      # The agent buffer should be stored in agent state
      assert is_pid(result.agent.buffer)
      assert Process.alive?(result.agent.buffer)
    end

    test "is a no-op when keymap_scope is :editor" do
      {:ok, scratch} = BufferServer.start_link(content: "scratch")
      window = Window.new(1, scratch, 24, 80)

      state = %EditorState{
        port_manager: self(),
        viewport: Viewport.new(24, 80),
        mode: :normal,
        mode_state: Mode.initial_state(),
        keymap_scope: :editor,
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => window},
          active: 1,
          next_id: 2
        },
        focus_stack: Input.default_stack()
      }

      result = Startup.maybe_apply_agent_split(state)

      refute LayoutPreset.has_agent_chat?(result)
      assert result.windows.tree == WindowTree.new(1)
      assert map_size(result.windows.map) == 1
    end
  end
end
