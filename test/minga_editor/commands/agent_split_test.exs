defmodule MingaEditor.Commands.AgentSplitTest do
  use ExUnit.Case, async: true

  alias Minga.Parser.Manager
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.HighlightSync
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias Minga.Test.StubServer

  defp make_state(opts \\ []) do
    {:ok, buf} =
      BufferProcess.start_link(
        content: "hello world",
        filetype: Keyword.get(opts, :filetype, :text)
      )

    {:ok, _prompt_buf} = BufferProcess.start_link(content: "")
    {:ok, fake_session} = StubServer.start_link()

    window = Window.new(1, buf, 24, 80)

    agent = %AgentState{}

    # File tab with context
    file_tab = Tab.new_file(1, "[no file]")

    file_context = %{
      keymap_scope: :editor,
      windows: %Windows{
        tree: {:leaf, 1},
        map: %{1 => window},
        active: 1,
        next_id: 2
      }
    }

    file_tab = Tab.set_context(file_tab, file_context)

    # Agent tab with context containing an agent_chat window. The session pid
    # lives on the workspace and projects onto the associated tab.
    agent_tab = Tab.new_agent(2, "Agent")

    agent_win = Window.new_agent_chat(1, 24, 80)

    agent_context = %{
      keymap_scope: :agent,
      windows: %Windows{
        tree: {:leaf, 1},
        map: %{1 => agent_win},
        active: 1,
        next_id: 2
      }
    }

    agent_tab = Tab.set_context(agent_tab, agent_context)

    tb = %TabBar{
      tabs: [file_tab, agent_tab],
      active_id: 1,
      next_id: 3
    }

    {tb, workspace} = TabBar.add_workspace(tb, "Agent", fake_session)
    tb = TabBar.move_tab_to_workspace(tb, agent_tab.id, workspace.id)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %MingaEditor.Session.State{
        buffers: %Buffers{active: buf, list: [buf]},
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      },
      parser:
        MingaEditor.State.Parser.new(Keyword.get(opts, :parser_manager, Minga.Parser.Manager)),
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Traditional.State.replace_agent(
              %MingaEditor.Shell.Traditional.State{},
              agent
            ),
            tb
          )
        )
    }
  end

  describe "toggle_agent_split/1" do
    test "switches to agent tab when on file tab" do
      state = make_state()
      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :file

      new_state = AgentCommands.toggle_agent_split(state)

      assert MingaEditor.Shell.Runtime.active_tab_kind(new_state.shell_runtime) == :agent
      assert new_state.shell_runtime.state.tab_bar.active_id == 2
    end

    test "switches back to file tab when on agent tab" do
      state = make_state()

      # Toggle on (switch to agent)
      state = AgentCommands.toggle_agent_split(state)
      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :agent

      # Toggle off (switch to file)
      state = AgentCommands.toggle_agent_split(state)
      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :file
      assert state.shell_runtime.state.tab_bar.active_id == 1
    end

    test "agent tab has agent_chat window in context" do
      state = make_state()
      state = AgentCommands.toggle_agent_split(state)

      # After switching to agent tab, the windows should include an agent_chat window
      agent_win =
        Map.values(state.workspace.windows.map) |> Enum.find(&Content.agent_chat?(&1.content))

      assert agent_win != nil
    end

    test "no-tab return restores parser presentation for the saved active buffer", %{test: test} do
      manager =
        start_supervised!(
          {Manager,
           name: Module.concat(__MODULE__, "Parser#{test}"), parser_path: "/missing/minga-parser"}
        )

      state = make_state(filetype: :elixir, parser_manager: manager)
      saved_buffer = state.workspace.buffers.active

      return_target =
        UIState.return_target(
          1,
          saved_buffer,
          state.workspace.windows,
          state.workspace.file_tree,
          :editor,
          false
        )

      {:ok, agent_buffer} = BufferProcess.start_link(content: "agent view")

      state =
        state
        |> then(fn state ->
          buffers = %Buffers{
            active: agent_buffer,
            list: [agent_buffer, saved_buffer],
            active_index: 0
          }

          workspace = %{
            state.workspace
            | buffers: buffers,
              agent_ui:
                UIState.activate(
                  %UIState{},
                  state.workspace.windows,
                  state.workspace.file_tree,
                  return_target
                )
          }

          shell_state =
            MingaEditor.Shell.Traditional.State.replace_agent(
              %MingaEditor.Shell.Traditional.State{},
              %AgentState{}
            )

          %{
            state
            | workspace: workspace,
              shell_runtime: Runtime.new(Runtime.default_entry(), shell_state)
          }
        end)
        |> HighlightSync.setup_for_buffer_pid(saved_buffer)

      assert is_integer(Manager.buffer_id(saved_buffer, manager))

      Process.sleep(2)

      evicted = HighlightSync.evict_inactive(state, ttl_ms: 0)

      assert Manager.buffer_id(saved_buffer, manager) == nil
      refute Map.has_key?(evicted.parser.highlighting.highlights, saved_buffer)

      returned = AgentCommands.return_to_editor(evicted)

      assert returned.workspace.buffers.active == saved_buffer
      assert is_integer(Manager.buffer_id(saved_buffer, manager))
      assert Map.has_key?(returned.parser.highlighting.highlights, saved_buffer)
    end

    test "round-trip toggle restores file state" do
      state = make_state()
      original_buf = state.workspace.buffers.active
      original_active = state.shell_runtime.state.tab_bar.active_id

      state = AgentCommands.toggle_agent_split(state)
      state = AgentCommands.toggle_agent_split(state)

      assert state.shell_runtime.state.tab_bar.active_id == original_active
      assert state.workspace.buffers.active == original_buf
    end
  end
end
