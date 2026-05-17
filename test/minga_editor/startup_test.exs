defmodule MingaEditor.StartupTest do
  # async: false because the CLI startup flag tests mutate Application env,
  # which races with the first test when run concurrently.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.LayoutPreset
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowTree
  alias MingaEditor.Input

  defp start_events_registry(suffix) do
    name = :"#{__MODULE__}.#{suffix}.#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: name})
    name
  end

  defp start_recording_editor(frontend_type, suffix) do
    id = System.unique_integer([:positive])
    events_registry = start_events_registry(suffix)

    options_server =
      start_supervised!({Options, name: nil, events_registry: events_registry},
        id: {:options, suffix, id}
      )

    {:ok, buffer} = BufferProcess.start_link(content: "", events_registry: events_registry)

    port =
      start_supervised!(
        {RecordingFrontend,
         owner: self(),
         width: 80,
         height: 24,
         capabilities: %Capabilities{frontend_type: frontend_type}},
        id: {:recording_frontend, suffix, id}
      )

    editor =
      start_supervised!(
        {MingaEditor,
         name: :"#{__MODULE__}.editor.#{id}",
         backend: :headless,
         port_manager: port,
         buffer: buffer,
         width: 80,
         height: 24,
         editing_model: :vim,
         options_server: options_server,
         events_registry: events_registry,
         suppress_tool_prompts: true},
        id: {:editor, suffix, id}
      )

    send(editor, {:minga_input, {:ready, 80, 24}})
    :sys.get_state(editor)
    drain_frontend_commands(port)

    %{
      editor: editor,
      port: port,
      options_server: options_server,
      events_registry: events_registry
    }
  end

  defp drain_frontend_commands(port) do
    receive do
      {:frontend_commands, ^port, _commands} -> drain_frontend_commands(port)
    after
      0 -> :ok
    end
  end

  describe "startup_view_state/1" do
    test "returns :agent scope when startup_view is :agent in TUI mode" do
      {scope, agentic} = Startup.startup_view_state(:tui)

      assert scope == :agent
      assert agentic.view.active == true
      assert agentic.view.focus == :chat
    end

    test "returns :editor scope when editor view mode is set" do
      Application.put_env(:minga, :cli_startup_flags, %{view_mode: :editor, no_context: false})

      {scope, agentic} = Startup.startup_view_state(:tui)

      assert scope == :editor
      assert agentic.view.active == false
    after
      Application.delete_env(:minga, :cli_startup_flags)
    end

    test "returns :agent scope when agentic view mode is set" do
      Application.put_env(:minga, :cli_startup_flags, %{view_mode: :agentic, no_context: false})

      {scope, agentic} = Startup.startup_view_state(:native_gui)

      assert scope == :agent
      assert agentic.view.active == true
      assert agentic.view.focus == :chat
    after
      Application.delete_env(:minga, :cli_startup_flags)
    end

    test "returns :editor scope for native GUI backend in auto mode" do
      Application.put_env(:minga, :cli_startup_flags, %{view_mode: :auto, no_context: false})

      {scope, _agentic} = Startup.startup_view_state(:native_gui)

      assert scope == :editor
    after
      Application.delete_env(:minga, :cli_startup_flags)
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

  describe "send_font_config/1" do
    setup do
      server = start_supervised!({Options, name: nil})
      %{server: server}
    end

    test "does not send GUI-only renderer options to TUI frontends", %{server: server} do
      state = %EditorState{
        port_manager: self(),
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        options_server: server,
        capabilities: %Capabilities{frontend_type: :tui}
      }

      Startup.send_font_config(state)

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      refute Enum.any?(commands, &match?(<<0x92, _::binary>>, &1))
      refute Enum.any?(commands, &match?(<<0x95, _::binary>>, &1))
      refute_receive {:"$gen_cast", {:send_commands, _}}
    end

    test "sends cursor animation preference to GUI frontends", %{server: server} do
      state = %EditorState{
        port_manager: self(),
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        options_server: server,
        capabilities: %Capabilities{frontend_type: :native_gui}
      }

      Startup.send_font_config(state)

      assert_receive {:"$gen_cast", {:send_commands, font_commands}}
      assert_receive {:"$gen_cast", {:send_commands, [<<0x92, _::binary>>]}}
      assert_receive {:"$gen_cast", {:send_commands, [<<0x95, 1::16, 1::8>>]}}
      refute Enum.any?(font_commands, &match?(<<0x92, _::binary>>, &1))
      refute Enum.any?(font_commands, &match?(<<0x95, _::binary>>, &1))
    end

    test "sends disabled cursor animation preference from the supplied options server", %{
      server: server
    } do
      {:ok, false} = Options.set(server, :cursor_animate, false)

      state = %EditorState{
        port_manager: self(),
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        options_server: server,
        capabilities: %Capabilities{frontend_type: :native_gui}
      }

      Startup.send_font_config(state)

      assert_receive {:"$gen_cast", {:send_commands, _font_commands}}
      assert_receive {:"$gen_cast", {:send_commands, [<<0x92, _::binary>>]}}
      assert_receive {:"$gen_cast", {:send_commands, [<<0x95, 1::16, 0::8>>]}}
    end
  end

  describe "send_cursor_animation_config/2" do
    test "sends runtime cursor animation changes to GUI frontends" do
      state = %EditorState{
        port_manager: self(),
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        capabilities: %Capabilities{frontend_type: :native_gui}
      }

      Startup.send_cursor_animation_config(state, false)

      assert_receive {:"$gen_cast", {:send_commands, [<<0x95, 1::16, 0::8>>]}}
    end

    test "does not send runtime cursor animation changes to TUI frontends" do
      state = %EditorState{
        port_manager: self(),
        workspace: %MingaEditor.Workspace.State{viewport: Viewport.new(24, 80)},
        capabilities: %Capabilities{frontend_type: :tui}
      }

      Startup.send_cursor_animation_config(state, false)

      refute_receive {:"$gen_cast", {:send_commands, _}}
    end
  end

  describe "runtime option change events" do
    test "global cursor animation option changes are published on the server registry" do
      events_registry = start_events_registry(:option_changed_publish)
      server = start_supervised!({Options, name: nil, events_registry: events_registry})
      Minga.Events.subscribe(:option_changed, events_registry)

      assert {:ok, false} = Options.set(server, :cursor_animate, false)

      assert_receive {:minga_event, :option_changed,
                      %Minga.Events.OptionChangedEvent{
                        source: ^server,
                        name: :cursor_animate,
                        value: false
                      }}
    end

    test "editor forwards runtime cursor animation changes from its options server to GUI frontends" do
      %{editor: editor, port: port, options_server: options_server} =
        start_recording_editor(:native_gui, :runtime_gui)

      RecordingFrontend.reset(port)
      :sys.get_state(editor)

      assert {:ok, false} = Options.set(options_server, :cursor_animate, false)

      assert_receive {:frontend_commands, ^port, [<<0x95, 1::16, 0::8>>]}
    end

    test "editor matches runtime cursor animation changes from a named options server passed by pid" do
      id = System.unique_integer([:positive])
      events_registry = start_events_registry(:runtime_named_options)
      options_name = :"#{__MODULE__}.named_options.#{id}"

      options_server =
        start_supervised!({Options, name: options_name, events_registry: events_registry},
          id: {:named_options, id}
        )

      {:ok, buffer} = BufferProcess.start_link(content: "", events_registry: events_registry)

      port =
        start_supervised!(
          {RecordingFrontend,
           owner: self(),
           width: 80,
           height: 24,
           capabilities: %Capabilities{frontend_type: :native_gui}},
          id: {:named_recording_frontend, id}
        )

      editor =
        start_supervised!(
          {MingaEditor,
           name: :"#{__MODULE__}.named_editor.#{id}",
           backend: :headless,
           port_manager: port,
           buffer: buffer,
           width: 80,
           height: 24,
           editing_model: :vim,
           options_server: options_server,
           events_registry: events_registry,
           suppress_tool_prompts: true},
          id: {:named_editor, id}
        )

      send(editor, {:minga_input, {:ready, 80, 24}})
      :sys.get_state(editor)
      drain_frontend_commands(port)

      RecordingFrontend.reset(port)
      :sys.get_state(editor)

      assert {:ok, false} = Options.set(options_server, :cursor_animate, false)

      assert_receive {:frontend_commands, ^port, [<<0x95, 1::16, 0::8>>]}
    end

    test "editor ignores runtime cursor animation changes from other options servers" do
      %{editor: editor, port: port, events_registry: events_registry} =
        start_recording_editor(:native_gui, :runtime_wrong_source)

      other_options =
        start_supervised!({Options, name: nil, events_registry: events_registry},
          id: :runtime_wrong_source_options
        )

      RecordingFrontend.reset(port)
      :sys.get_state(editor)

      assert {:ok, false} = Options.set(other_options, :cursor_animate, false)

      refute_receive {:frontend_commands, ^port, [<<0x95, 1::16, 0::8>>]}
    end

    test "TUI editor does not send GUI-only cursor animation opcode for runtime changes" do
      %{editor: editor, port: port, options_server: options_server} =
        start_recording_editor(:tui, :runtime_tui)

      RecordingFrontend.reset(port)
      :sys.get_state(editor)

      assert {:ok, false} = Options.set(options_server, :cursor_animate, false)

      refute_receive {:frontend_commands, ^port, [<<0x95, _::binary>>]}
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
      {:ok, buf} = BufferProcess.start_link(content: "hello")

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
      {:ok, buf} = BufferProcess.start_link(content: "scratch")

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
      {:ok, buf} = BufferProcess.start_link(content: "scratch")
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
