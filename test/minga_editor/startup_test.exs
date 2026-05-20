defmodule MingaEditor.StartupTest do
  # async: false because startup_view_state/1 reads global CLI startup flags from Application env.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Input
  alias MingaEditor.LayoutPreset
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowTree

  describe "startup_view_state/1" do
    test "defaults to agent view for TUI startup" do
      {scope, agentic} = Startup.startup_view_state(:tui)

      assert scope == :agent
      assert agentic.view.active == true
      assert agentic.view.focus == :chat
    end

    test "CLI startup flags select editor, agentic, and native GUI auto modes" do
      assert_startup_scope(:tui, :editor, :editor, false)
      assert_startup_scope(:native_gui, :agentic, :agent, true)
      assert_startup_scope(:native_gui, :auto, :editor, false)
    end
  end

  describe "apply_gui_defaults/2" do
    setup do
      %{server: start_supervised!({Options, name: nil})}
    end

    test "GUI frontends get GUI defaults while TUI frontends keep shared defaults", %{
      server: server
    } do
      Startup.apply_gui_defaults(%Capabilities{frontend_type: :native_gui}, server)

      assert Options.get(server, :line_spacing) == 1.2
      assert Options.get(server, :line_numbers) == :absolute

      tui_server = start_supervised!({Options, name: nil}, id: :tui_gui_defaults)
      Startup.apply_gui_defaults(%Capabilities{frontend_type: :tui}, tui_server)

      assert Options.get(tui_server, :line_spacing) == 1.0
      assert Options.get(tui_server, :line_numbers) == :hybrid
    end

    test "explicit user overrides win over GUI defaults", %{server: server} do
      {:ok, _} = Options.set(server, :line_spacing, 1.5)
      {:ok, _} = Options.set(server, :line_numbers, :relative)

      Startup.apply_gui_defaults(%Capabilities{frontend_type: :native_gui}, server)

      assert Options.get(server, :line_spacing) == 1.5
      assert Options.get(server, :line_numbers) == :relative
    end

    test "writes land on the supplied options server only" do
      server_a = start_supervised!({Options, name: nil}, id: :gui_defaults_a)
      server_b = start_supervised!({Options, name: nil}, id: :gui_defaults_b)

      Startup.apply_gui_defaults(%Capabilities{frontend_type: :native_gui}, server_a)

      assert Options.get(server_a, :line_numbers) == :absolute
      assert Options.get(server_a, :line_spacing) == 1.2
      assert Options.get(server_b, :line_numbers) == :hybrid
      assert Options.get(server_b, :line_spacing) == 1.0
    end
  end

  describe "send_font_config/1" do
    setup do
      %{server: start_supervised!({Options, name: nil})}
    end

    test "TUI font config excludes GUI-only opcodes", %{server: server} do
      Startup.send_font_config(state_for_frontend(:tui, server))

      assert_receive {:"$gen_cast", {:send_commands, commands}}
      refute Enum.any?(commands, &cursor_animation_opcode?/1)
      refute Enum.any?(commands, &gui_font_option_opcode?/1)
      refute_receive {:"$gen_cast", {:send_commands, _}}
    end

    test "GUI font config includes cursor animation from the supplied options server", %{
      server: server
    } do
      Startup.send_font_config(state_for_frontend(:native_gui, server))

      assert_receive {:"$gen_cast", {:send_commands, font_commands}}
      assert_receive {:"$gen_cast", {:send_commands, [<<0x92, _::binary>>]}}
      assert_receive {:"$gen_cast", {:send_commands, [<<0x95, 1::16, 1::8>>]}}
      refute Enum.any?(font_commands, &cursor_animation_opcode?/1)
      refute Enum.any?(font_commands, &gui_font_option_opcode?/1)

      {:ok, false} = Options.set(server, :cursor_animate, false)
      Startup.send_font_config(state_for_frontend(:native_gui, server))

      assert_receive {:"$gen_cast", {:send_commands, _font_commands}}
      assert_receive {:"$gen_cast", {:send_commands, [<<0x92, _::binary>>]}}
      assert_receive {:"$gen_cast", {:send_commands, [<<0x95, 1::16, 0::8>>]}}
    end
  end

  describe "send_cursor_animation_config/2" do
    test "runtime cursor animation changes are GUI-only" do
      Startup.send_cursor_animation_config(state_for_frontend(:native_gui), false)
      assert_receive {:"$gen_cast", {:send_commands, [<<0x95, 1::16, 0::8>>]}}

      Startup.send_cursor_animation_config(state_for_frontend(:tui), false)
      refute_receive {:"$gen_cast", {:send_commands, _}}
    end
  end

  describe "runtime option change events" do
    test "editor forwards cursor animation changes from its own options server and ignores others" do
      %{
        editor: editor,
        port: port,
        options_server: options_server,
        events_registry: events_registry
      } =
        start_recording_editor(:native_gui, :runtime_gui)

      RecordingFrontend.reset(port)
      sync_editor(editor)

      assert {:ok, false} = Options.set(options_server, :cursor_animate, false)
      assert_receive {:frontend_commands, ^port, [<<0x95, 1::16, 0::8>>]}

      other_options =
        start_supervised!({Options, name: nil, events_registry: events_registry},
          id: :runtime_wrong_source_options
        )

      RecordingFrontend.reset(port)
      sync_editor(editor)

      assert {:ok, false} = Options.set(other_options, :cursor_animate, false)
      refute_receive {:frontend_commands, ^port, [<<0x95, 1::16, 0::8>>]}
    end

    test "TUI editor ignores GUI-only cursor animation runtime changes" do
      %{editor: editor, port: port, options_server: options_server} =
        start_recording_editor(:tui, :runtime_tui)

      RecordingFrontend.reset(port)
      sync_editor(editor)

      assert {:ok, false} = Options.set(options_server, :cursor_animate, false)
      refute_receive {:frontend_commands, ^port, [<<0x95, _::binary>>]}
    end
  end

  describe "build_initial_state/1" do
    test "normalizes nil and supplied options servers" do
      default_state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: nil,
          width: 80,
          height: 24
        )

      assert default_state.options_server == Options.default_server()

      options_server = start_supervised!({Options, name: __MODULE__})

      assert {:ok, false} =
               Options.set_for_filetype(options_server, :text, :autopair_block, false)

      custom_state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: options_server,
          width: 80,
          height: 24
        )

      assert custom_state.options_server == options_server

      assert BufferProcess.get_option(custom_state.workspace.buffers.active, :autopair_block) ==
               false
    end
  end

  describe "build_initial_window/5" do
    test "agent startup creates an agent chat window and editor startup creates a buffer window" do
      {agent_window, {:agent_buffer, agent_buf}} =
        Startup.build_initial_window(:agent, 1, self(), 24, 80)

      assert %Window{} = agent_window
      assert Content.agent_chat?(agent_window.content)
      refute Content.buffer?(agent_window.content)
      assert is_pid(agent_buf)
      assert Process.alive?(agent_buf)

      {:ok, buf} = BufferProcess.start_link(content: "hello")
      {editor_window, :noop} = Startup.build_initial_window(:editor, 1, buf, 24, 80)

      assert %Window{} = editor_window
      assert Content.buffer?(editor_window.content)
      assert editor_window.buffer == buf
    end

    test "editor startup with nil buffer returns no window" do
      assert {nil, :noop} = Startup.build_initial_window(:editor, 1, nil, 24, 80)
    end
  end

  describe "startup window shape" do
    test "initial windows match LayoutPreset agent-chat detection" do
      {:ok, buf} = BufferProcess.start_link(content: "scratch")

      {agent_window, {:agent_buffer, _agent_buf}} =
        Startup.build_initial_window(:agent, 1, buf, 24, 80)

      {editor_window, :noop} = Startup.build_initial_window(:editor, 1, buf, 24, 80)

      agent_state = window_state(:agent, agent_window)
      editor_state = window_state(:editor, editor_window)

      assert LayoutPreset.has_agent_chat?(agent_state)
      refute LayoutPreset.has_agent_chat?(editor_state)
      assert {:leaf, 1} = agent_state.workspace.windows.tree
      assert map_size(agent_state.workspace.windows.map) == 1
    end
  end

  defp assert_startup_scope(backend, view_mode, expected_scope, expected_active?) do
    Application.put_env(:minga, :cli_startup_flags, %{view_mode: view_mode, no_context: false})

    {scope, agentic} = Startup.startup_view_state(backend)

    assert scope == expected_scope
    assert agentic.view.active == expected_active?
  after
    Application.delete_env(:minga, :cli_startup_flags)
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
    sync_editor(editor)
    drain_frontend_commands(port)

    %{
      editor: editor,
      port: port,
      options_server: options_server,
      events_registry: events_registry
    }
  end

  defp start_events_registry(suffix) do
    name = :"#{__MODULE__}.#{suffix}.#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: name})
    name
  end

  defp sync_editor(editor), do: GenServer.call(editor, :api_mode)

  defp drain_frontend_commands(port) do
    receive do
      {:frontend_commands, ^port, _commands} -> drain_frontend_commands(port)
    after
      0 -> :ok
    end
  end

  defp state_for_frontend(frontend_type, server \\ nil) do
    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Session.State{viewport: Viewport.new(24, 80)},
      options_server: server || Options.default_server(),
      capabilities: %Capabilities{frontend_type: frontend_type}
    }
  end

  defp window_state(scope, window) do
    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: scope,
        windows: %Windows{tree: WindowTree.new(1), map: %{1 => window}, active: 1, next_id: 2}
      },
      focus_stack: Input.default_stack()
    }
  end

  defp cursor_animation_opcode?(<<0x95, _::binary>>), do: true
  defp cursor_animation_opcode?(_), do: false

  defp gui_font_option_opcode?(<<0x92, _::binary>>), do: true
  defp gui_font_option_opcode?(_), do: false
end
