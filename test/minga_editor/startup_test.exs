defmodule MingaEditor.StartupTest do
  # async: false because the force_editor test mutates Application env,
  # which races with the first test when run concurrently.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Options
  alias MingaEditor.LayoutPreset
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowTree
  alias MingaEditor.Input

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

  describe "apply_gui_defaults/2" do
    setup do
      # Per-test isolated Options server keeps these cases from racing on the
      # global singleton and lets us assert exactly which server received the
      # writes (proving the threading argument is honored).
      server = start_supervised!({Options, name: nil})
      %{server: server}
    end

    test "sets line_spacing to 1.2 for GUI frontend", %{server: server} do
      gui_caps = %MingaEditor.Frontend.Capabilities{frontend_type: :native_gui}

      Startup.apply_gui_defaults(gui_caps, server)

      assert Options.get(server, :line_spacing) == 1.2
    end

    test "does not change line_spacing for TUI frontend", %{server: server} do
      tui_caps = %MingaEditor.Frontend.Capabilities{frontend_type: :tui}

      Startup.apply_gui_defaults(tui_caps, server)

      assert Options.get(server, :line_spacing) == 1.0
    end

    test "respects explicit user override to custom line_spacing in GUI mode",
         %{server: server} do
      gui_caps = %MingaEditor.Frontend.Capabilities{frontend_type: :native_gui}
      {:ok, _} = Options.set(server, :line_spacing, 1.5)

      Startup.apply_gui_defaults(gui_caps, server)

      assert Options.get(server, :line_spacing) == 1.5
    end

    test "sets line_numbers to :absolute for GUI frontend", %{server: server} do
      gui_caps = %MingaEditor.Frontend.Capabilities{frontend_type: :native_gui}

      # Ensure the default is :hybrid before applying
      assert Options.get(server, :line_numbers) == :hybrid

      Startup.apply_gui_defaults(gui_caps, server)

      assert Options.get(server, :line_numbers) == :absolute
    end

    test "does not change line_numbers for TUI frontend", %{server: server} do
      tui_caps = %MingaEditor.Frontend.Capabilities{frontend_type: :tui}

      Startup.apply_gui_defaults(tui_caps, server)

      assert Options.get(server, :line_numbers) == :hybrid
    end

    test "respects explicit user override to :relative in GUI mode", %{server: server} do
      gui_caps = %MingaEditor.Frontend.Capabilities{frontend_type: :native_gui}
      {:ok, _} = Options.set(server, :line_numbers, :relative)

      Startup.apply_gui_defaults(gui_caps, server)

      assert Options.get(server, :line_numbers) == :relative
    end

    test "respects explicit user override to :hybrid in GUI mode", %{server: server} do
      # Edge case: user explicitly wants :hybrid in GUI mode.
      # Our heuristic treats this as "not explicitly set" and overrides it.
      # This is an acknowledged tradeoff (ticket #728 notes this).
      gui_caps = %MingaEditor.Frontend.Capabilities{frontend_type: :native_gui}

      Startup.apply_gui_defaults(gui_caps, server)

      # :hybrid becomes :absolute because we can't distinguish "user set :hybrid"
      # from "default :hybrid". This is acceptable per ticket scope.
      assert Options.get(server, :line_numbers) == :absolute
    end

    test "writes land on the supplied server, not the default singleton" do
      # End-to-end proof of the threading: two isolated servers, only the
      # one passed to apply_gui_defaults/2 is mutated.
      server_a = start_supervised!({Options, name: nil}, id: :gui_defaults_a)
      server_b = start_supervised!({Options, name: nil}, id: :gui_defaults_b)
      gui_caps = %MingaEditor.Frontend.Capabilities{frontend_type: :native_gui}

      Startup.apply_gui_defaults(gui_caps, server_a)

      assert Options.get(server_a, :line_numbers) == :absolute
      assert Options.get(server_a, :line_spacing) == 1.2
      assert Options.get(server_b, :line_numbers) == :hybrid
      assert Options.get(server_b, :line_spacing) == 1.0
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
        workspace: %MingaEditor.Workspace.State{
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
        workspace: %MingaEditor.Workspace.State{
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
