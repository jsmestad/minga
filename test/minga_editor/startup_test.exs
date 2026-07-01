defmodule MingaEditor.StartupTest do
  # async: false because startup_view_state/1 reads global CLI startup flags from Application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Project.FileRef
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Input
  alias MingaEditor.Input.FileTreeHandler
  alias MingaEditor.LayoutPreset
  alias MingaEditor.Shell.Registry, as: ShellRegistry
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Session
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.Persistence
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowTree

  describe "startup_view_state/1" do
    test "defaults to editor view for TUI startup" do
      {scope, ui_state} = Startup.startup_view_state(:tui)

      assert scope == :editor
      assert ui_state.view.active == false
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

    test "GUI font config no longer pushes line_spacing or cursor_animation (#2119)", %{
      server: server
    } do
      # line_spacing (0x92) and cursor_animation (0x95) moved in-frame as semantic
      # models, so send_font_config sends only the font setup, never those opcodes.
      Startup.send_font_config(state_for_frontend(:native_gui, server))

      assert_receive {:"$gen_cast", {:send_commands, font_commands}}
      refute Enum.any?(font_commands, &cursor_animation_opcode?/1)
      refute Enum.any?(font_commands, &gui_font_option_opcode?/1)
      refute_receive {:"$gen_cast", {:send_commands, [<<0x92, _::binary>>]}}
      refute_receive {:"$gen_cast", {:send_commands, [<<0x95, _::binary>>]}}
    end
  end

  describe "runtime option change events" do
    test "GUI editor re-emits cursor animation in-frame on its own options server change (#2119)" do
      %{
        editor: editor,
        port: port,
        options_server: options_server,
        events_registry: events_registry
      } =
        start_recording_editor(:native_gui, :runtime_gui)

      RecordingFrontend.reset(port)
      sync_editor(editor)

      # cursor_animate now rides in-frame: changing it triggers a re-render whose
      # frame transaction carries the gui_cursor_animation command (0x95).
      assert {:ok, false} = Options.set(options_server, :cursor_animate, false)
      sync_editor(editor)

      assert recorded_cursor_animation(port) == false

      other_options =
        start_supervised!({Options, name: nil, events_registry: events_registry},
          id: :runtime_wrong_source_options
        )

      RecordingFrontend.reset(port)
      sync_editor(editor)

      # A change on a different options server is ignored: no re-render, so no
      # cursor_animation command reaches this editor's port.
      assert {:ok, false} = Options.set(other_options, :cursor_animate, false)
      sync_editor(editor)
      assert recorded_cursor_animation(port) == nil
    end

    test "TUI editor never emits the GUI-only cursor animation command" do
      %{editor: editor, port: port, options_server: options_server} =
        start_recording_editor(:tui, :runtime_tui)

      RecordingFrontend.reset(port)
      sync_editor(editor)

      assert {:ok, false} = Options.set(options_server, :cursor_animate, false)
      sync_editor(editor)
      assert recorded_cursor_animation(port) == nil
    end
  end

  describe "build_initial_state/1" do
    test "empty launch (no file buffer) opens a normal blank active buffer, never a nil active" do
      # Regression pin for the dashboard removal (#2323). The dashboard was the
      # only path that left buffers.active == nil; with it gone, an empty launch
      # must always land on a real blank buffer so input/render never route to a
      # missing surface.
      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: nil,
          view_mode: :editor,
          width: 80,
          height: 24,
          sidebar_registry: private_sidebar_registry()
        )

      active = state.workspace.buffers.active
      assert is_pid(active)
      assert active in state.workspace.buffers.list
      # No modal overlay is pushed on an empty launch.
      assert state.shell_state.modal == :none
      assert state.message_store.stream_instance > 0
    end

    test "uses supplied options server for automatic startup view" do
      options_server = start_supervised!({Options, name: nil})
      {:ok, :agent} = Options.set(options_server, :startup_view, :agent)
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :cli_startup_flags, %{view_mode: :auto, no_context: false})

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: options_server,
          width: 80,
          height: 24,
          sidebar_registry: private_sidebar_registry()
        )

      assert state.workspace.keymap_scope == :agent
      assert state.workspace.agent_ui.view.active
    after
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.delete_env(:minga, :cli_startup_flags)
    end

    test "explicit view_mode overrides configured startup view" do
      options_server = start_supervised!({Options, name: nil})
      {:ok, :agent} = Options.set(options_server, :startup_view, :agent)
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :cli_startup_flags, %{view_mode: :auto, no_context: false})

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: options_server,
          view_mode: :editor,
          width: 80,
          height: 24,
          sidebar_registry: private_sidebar_registry()
        )

      assert state.workspace.keymap_scope == :editor
      refute state.workspace.agent_ui.view.active
    after
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.delete_env(:minga, :cli_startup_flags)
    end

    test "registers FileTree dynamic sidebar and input contributions" do
      Input.reset_handlers()
      sidebar_registry = private_sidebar_registry()

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: nil,
          width: 80,
          height: 24,
          sidebar_registry: sidebar_registry
        )

      assert %{id: "file_tree", input_handler: FileTreeHandler, visible?: false} =
               Sidebar.get(sidebar_registry, "file_tree")

      handlers = Input.surface_handlers(state)
      assert Enum.count(handlers, &(&1 == FileTreeHandler)) == 1
    after
      Input.reset_handlers()
    end

    test "falls back to default shell when explicit startup shell is unavailable" do
      ShellRegistry.reset_for_test()
      ShellRegistry.seed_builtin()

      {state, log} =
        with_log(fn ->
          Startup.build_initial_state(
            backend: :headless,
            port_manager: nil,
            parser_manager: nil,
            options_server: nil,
            width: 80,
            height: 24,
            shell: :missing_shell
          )
        end)

      assert log =~ "Requested shell :missing_shell is not registered"
      assert state.shell_id == :traditional
      assert state.shell == MingaEditor.Shell.Traditional
      assert state.shell_identity.module == MingaEditor.Shell.Traditional
      assert state.shell_identity.source == :builtin
    after
      ShellRegistry.reset_for_test()
      ShellRegistry.seed_builtin()
    end

    test "falls back with a warning when configured default shell is unavailable" do
      ShellRegistry.reset_for_test()
      ShellRegistry.seed_builtin()
      options_server = start_supervised!({Options, name: nil})
      Options.set_unchecked(options_server, :default_shell, :missing_shell)
      Process.put(:minga_config_options, options_server)

      {state, log} =
        with_log(fn ->
          Startup.build_initial_state(
            backend: :headless,
            port_manager: nil,
            parser_manager: nil,
            options_server: options_server,
            width: 80,
            height: 24
          )
        end)

      assert log =~ "Configured default shell :missing_shell is not registered"
      assert state.shell_id == :traditional
      assert state.shell == MingaEditor.Shell.Traditional
    after
      Process.delete(:minga_config_options)
      ShellRegistry.reset_for_test()
      ShellRegistry.seed_builtin()
    end

    test "apply_config_options uses the editor options server for the initial theme" do
      editor_options = start_supervised!({Options, name: nil}, id: :editor_theme_options)
      other_options = start_supervised!({Options, name: nil}, id: :other_theme_options)
      {:ok, :doom_one} = Options.set(editor_options, :theme, :doom_one)
      {:ok, :one_light} = Options.set(other_options, :theme, :one_light)
      Process.put(:minga_config_options, other_options)

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: editor_options,
          width: 80,
          height: 24
        )

      assert Startup.apply_config_options(state).theme.name == :doom_one
    after
      Process.delete(:minga_config_options)
    end

    test "apply_config_options raises when the configured theme is unavailable" do
      options_server = start_supervised!({Options, name: nil}, id: :missing_theme_options)
      {:ok, :astrodark} = Options.set(options_server, :theme, :astrodark)
      Minga.Extensions.ThemePacks.unregister_pack(Minga.Extensions.ThemePacks.AstroNvim)

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: options_server,
          width: 80,
          height: 24
        )

      assert_raise ArgumentError, ~r/unknown theme: :astrodark/, fn ->
        Startup.apply_config_options(state)
      end
    after
      Minga.Extensions.ThemePacks.register_pack(Minga.Extensions.ThemePacks.AstroNvim)
    end

    test "apply_config_options exits instead of silently keeping a fallback theme when options go away" do
      options_server = start_supervised!({Options, name: nil}, id: :gone_options)
      {:ok, _} = Options.set(options_server, :theme, :doom_one)

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: options_server,
          width: 80,
          height: 24
        )

      ref = Process.monitor(options_server)
      Process.exit(options_server, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^options_server, _}

      assert catch_exit(Startup.apply_config_options(state))
    end

    test "runtime theme application raises when the requested theme is unavailable" do
      options_server = start_supervised!({Options, name: nil}, id: :runtime_missing_theme_options)
      {:ok, :doom_one} = Options.set(options_server, :theme, :doom_one)
      Minga.Extensions.ThemePacks.unregister_pack(Minga.Extensions.ThemePacks.AstroNvim)

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: options_server,
          width: 80,
          height: 24
        )

      assert_raise ArgumentError, ~r/unknown theme: :astrodark/, fn ->
        MingaEditor.apply_runtime_config_option(state, :theme, :astrodark)
      end
    after
      Minga.Extensions.ThemePacks.register_pack(Minga.Extensions.ThemePacks.AstroNvim)
    end

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

    test "uses the CLI startup project root for initial workspace restore when opts omit project_root" do
      dir = tmp_dir("startup-project-root")
      workspace = Workspace.new_agent(2, "Persisted Agent", nil, dir)
      assert :ok = Persistence.write(workspace, dir)
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :cli_startup_project_root, dir)

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: nil,
          width: 80,
          height: 24,
          infer_project_root: true
        )

      tab_bar = EditorState.tab_bar(state)

      assert EditorState.file_tree_state(state).project_root == dir
      assert %Workspace{label: "Persisted Agent"} = TabBar.get_workspace(tab_bar, 2)
      assert tab_bar |> TabBar.switch_to_workspace(2) |> TabBar.active_workspace_id() == 2
    after
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.delete_env(:minga, :cli_startup_project_root)
    end

    test "uses argv-inferred project root for initial workspace restore when CLI env is absent" do
      original_argv = System.argv()
      on_exit(fn -> System.argv(original_argv) end)
      dir = tmp_dir("startup-argv-project-root")
      File.write!(Path.join(dir, "mix.exs"), "defmodule Example.MixProject do\nend\n")
      file = Path.join([dir, "lib", "example.ex"])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "defmodule Example do\nend\n")
      workspace = Workspace.new_agent(2, "Argv Agent", nil, dir)
      assert :ok = Persistence.write(workspace, dir)
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.delete_env(:minga, :cli_startup_project_root)
      System.argv([file])

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: nil,
          width: 80,
          height: 24,
          infer_project_root: true
        )

      tab_bar = EditorState.tab_bar(state)

      assert EditorState.file_tree_state(state).project_root == dir
      assert %Workspace{label: "Argv Agent"} = TabBar.get_workspace(tab_bar, 2)
    after
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.delete_env(:minga, :cli_startup_project_root)
    end

    test "invalid CLI startup project root does not break boot or restore workspaces" do
      original_argv = System.argv()
      on_exit(fn -> System.argv(original_argv) end)
      dir = tmp_dir("startup-invalid-project-root")
      invalid_root = Path.join(dir, "missing")
      workspace = Workspace.new_agent(2, "Hidden Agent", nil, dir)
      assert :ok = Persistence.write(workspace, dir)
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :cli_startup_project_root, invalid_root)
      System.argv([])

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: nil,
          width: 80,
          height: 24,
          infer_project_root: true
        )

      tab_bar = EditorState.tab_bar(state)

      assert EditorState.file_tree_state(state).project_root == invalid_root
      refute TabBar.get_workspace(tab_bar, 2)
    after
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.delete_env(:minga, :cli_startup_project_root)
    end

    test "switching to a restored agent workspace tab restores an agent-shaped editor context" do
      dir = tmp_dir("startup-restored-agent-tab")
      workspace = Workspace.new_agent(2, "Persisted Agent", nil, dir)
      assert :ok = Persistence.write(workspace, dir)
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :cli_startup_project_root, dir)

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: nil,
          width: 80,
          height: 24,
          infer_project_root: true
        )

      agent_tab =
        Enum.find(EditorState.tab_bar(state).tabs, &(&1.kind == :agent and &1.group_id == 2))

      assert %MingaEditor.State.Tab{} = agent_tab

      {restored, _effects} = EditorState.switch_tab_pure(state, agent_tab.id)
      active_window = Windows.active_struct(restored.workspace.windows)
      restored_tab = TabBar.active(EditorState.tab_bar(restored))

      assert restored.workspace.keymap_scope == :agent
      assert restored.workspace.agent_ui.view.active
      assert restored_tab.context.keymap_scope == :agent
      assert Content.agent_chat?(active_window.content)
      assert restored.workspace.buffers.active == nil
      assert restored.workspace.buffers.list == []
    after
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.delete_env(:minga, :cli_startup_project_root)
    end

    test "starting a session from a restored agent workspace reuses the restored workspace" do
      dir = tmp_dir("startup-restored-agent-session")
      file = Path.join([dir, "lib", "tracked.ex"])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "defmodule Tracked do\nend\n")
      {:ok, file_ref} = FileRef.from_path(dir, file)

      {:ok, workspace} =
        2
        |> Workspace.new_agent("Persisted Agent", nil, dir)
        |> Workspace.add_file(file_ref)
        |> Workspace.transition_review(:agent_started_editing, [file_ref])

      {:ok, workspace} = Workspace.transition_review(workspace, :agent_completed, [file_ref])
      assert :ok = Persistence.write(workspace, dir)
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.put_env(:minga, :cli_startup_project_root, dir)

      state =
        Startup.build_initial_state(
          backend: :headless,
          port_manager: nil,
          parser_manager: nil,
          options_server: nil,
          width: 80,
          height: 24,
          infer_project_root: true
        )

      restored_tab =
        Enum.find(EditorState.tab_bar(state).tabs, &(&1.kind == :agent and &1.group_id == 2))

      assert %MingaEditor.State.Tab{} = restored_tab
      {state, _effects} = EditorState.switch_tab_pure(state, restored_tab.id)
      state = AgentSession.start_agent_session(state)
      tab_bar = EditorState.tab_bar(state)
      active_tab = TabBar.active(tab_bar)
      session = active_tab.session
      on_exit(fn -> stop_session(session) end)

      agent_workspaces = Enum.filter(tab_bar.workspaces, &(&1.kind == :agent))
      rebound_workspace = TabBar.get_workspace(tab_bar, 2)

      assert is_pid(session)
      assert Enum.map(agent_workspaces, & &1.id) == [2]
      assert active_tab.group_id == 2
      assert rebound_workspace.session == session
      assert rebound_workspace.label == "Persisted Agent"
      assert rebound_workspace.files == [file_ref]
      assert rebound_workspace.review.state == :needs_review
      assert rebound_workspace.review.changed_files == [file_ref]
    after
      # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
      Application.delete_env(:minga, :cli_startup_project_root)
    end
  end

  describe "build_initial_window/5" do
    test "agent startup creates an agent chat window and editor startup creates a buffer window" do
      {agent_window, :semantic_agent_window} =
        Startup.build_initial_window(:agent, 1, self(), 24, 80)

      assert %Window{} = agent_window
      assert Content.agent_chat?(agent_window.content)
      refute Content.buffer?(agent_window.content)
      assert agent_window.buffer == nil

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

      {agent_window, :semantic_agent_window} =
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

  defp tmp_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "minga-startup-#{name}-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp stop_session(pid) when is_pid(pid) do
    MingaAgent.SessionManager.stop_session_by_pid(pid)
  catch
    :exit, _ -> :ok
  end

  defp stop_session(_pid), do: :ok

  defp assert_startup_scope(backend, view_mode, expected_scope, expected_active?) do
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.put_env(:minga, :cli_startup_flags, %{view_mode: view_mode, no_context: false})

    {scope, agentic} = Startup.startup_view_state(backend)

    assert scope == expected_scope
    assert agentic.view.active == expected_active?
  after
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
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

  defp state_for_frontend(frontend_type, server) do
    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Session.State{viewport: Viewport.new(24, 80)},
      options_server: server || Options.default_server(),
      capabilities: %Capabilities{frontend_type: frontend_type}
    }
  end

  describe "ensure_session_started/1" do
    test "runs once: flips session_started? on the first call" do
      state = %EditorState{
        port_manager: self(),
        workspace: nil,
        backend: :headless,
        session_started?: false
      }

      result = Startup.ensure_session_started(state)

      assert result.session_started? == true
    end

    test "is a no-op on an already-started state (renderer reconnect / hot-reload)" do
      # A reconnecting renderer re-sends `ready`, which must NOT re-run the
      # once-only startup work. The guard returns the state untouched, so no
      # duplicate save timer is created and swap recovery is not re-triggered.
      timer_ref = make_ref()

      state = %EditorState{
        port_manager: self(),
        workspace: nil,
        session_started?: true,
        session: %Session{timer: timer_ref}
      }

      assert Startup.ensure_session_started(state) == state
      assert Startup.ensure_session_started(state).session.timer == timer_ref
    end
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

  # Returns the decoded cursor-animation enabled flag from any gui_cursor_animation
  # (0x95) command recorded for this port, or nil if none was emitted.
  defp recorded_cursor_animation(port) do
    result =
      port
      |> RecordingFrontend.commands()
      |> Enum.find_value(fn
        <<0x95, _len::16, enabled::8, _rest::binary>> -> {:ok, enabled == 1}
        _ -> nil
      end)

    case result do
      {:ok, enabled?} -> enabled?
      nil -> nil
    end
  end

  defp private_sidebar_registry do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    table
  end
end
