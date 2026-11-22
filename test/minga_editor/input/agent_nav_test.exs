defmodule MingaEditor.Input.AgentNavTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Scroll
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Input.AgentNav
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Window

  @ctrl MingaEditor.Frontend.Protocol.mod_ctrl()
  @alt MingaEditor.Frontend.Protocol.mod_alt()

  defp make_state(opts) do
    prompt_buf = start_supervised!({BufferProcess, content: ""}, id: make_ref())
    file_buf = start_supervised!({BufferProcess, content: "file content"}, id: make_ref())

    scroll =
      Scroll.new(Keyword.get(opts, :offset, 5))
      |> Scroll.update_metrics(40, 10)

    agent_ui =
      %UIState{
        panel: %UIState.Panel{
          visible: true,
          scroll: scroll,
          prompt_buffer: prompt_buf
        }
      }
      |> UIState.activate(nil, nil)
      |> UIState.set_focus(Keyword.get(opts, :focus, :chat))
      |> UIState.set_input_focused(Keyword.get(opts, :input_focused, false))

    window = Window.new_agent_chat(1, 24, 80)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %MingaEditor.Session.State{
        agent_ui: agent_ui,
        buffers: %Buffers{active: file_buf, list: [file_buf]},
        keymap_scope: :agent,
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      },
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          MingaEditor.Shell.Traditional.State.replace_agent(
            %MingaEditor.Shell.Traditional.State{},
            %AgentState{}
          )
        )
    }
  end

  describe "chat focus navigation" do
    test "j scrolls the semantic transcript down" do
      state = make_state(offset: 5)

      {:handled, new_state} = AgentNav.handle_key(state, ?j, 0)

      assert new_state.workspace.agent_ui.panel.scroll.offset == 6
      refute new_state.workspace.agent_ui.panel.scroll.pinned
    end

    test "k scrolls the semantic transcript up" do
      state = make_state(offset: 5)

      {:handled, new_state} = AgentNav.handle_key(state, ?k, 0)

      assert new_state.workspace.agent_ui.panel.scroll.offset == 4
      refute new_state.workspace.agent_ui.panel.scroll.pinned
    end

    test "Ctrl-D and Ctrl-U page the semantic transcript" do
      {:handled, down_state} = AgentNav.handle_key(make_state(offset: 5), ?d, @ctrl)
      assert down_state.workspace.agent_ui.panel.scroll.offset == 15

      {:handled, up_state} = AgentNav.handle_key(make_state(offset: 15), ?u, @ctrl)
      assert up_state.workspace.agent_ui.panel.scroll.offset == 5
    end

    test "G pins the semantic transcript to the bottom" do
      state = make_state(offset: 5)

      {:handled, new_state} = AgentNav.handle_key(state, ?G, 0)

      assert new_state.workspace.agent_ui.panel.scroll.pinned
    end

    test "unpins the agent chat window when user navigates" do
      state = make_state(offset: 5)

      {:handled, new_state} = AgentNav.handle_key(state, ?j, 0)

      assert Map.fetch!(new_state.workspace.windows.map, 1).pinned == false
    end
  end

  describe "file viewer navigation" do
    test "routes j/k to file viewer scroll state" do
      state = make_state(focus: :file_viewer)

      {:handled, down_state} = AgentNav.handle_key(state, ?j, 0)
      assert down_state.workspace.agent_ui.view.preview.scroll.offset == 1

      {:handled, up_state} = AgentNav.handle_key(down_state, ?k, 0)
      assert up_state.workspace.agent_ui.view.preview.scroll.offset == 0
    end

    test "unclaimed viewer and chat keys stop before buffer editing while focused drafts still delegate" do
      for state <- [make_state(focus: :file_viewer), make_state(focus: :chat)],
          {cp, mods} <- [{?r, 0}, {?p, 0}, {?x, 0}, {?y, @ctrl}, {?r, @ctrl}, {0x754C, 0}] do
        assert {:handled, ^state} = AgentNav.handle_key(state, cp, mods)
      end

      draft = make_state(focus: :file_viewer, input_focused: true)
      assert {:passthrough, ^draft} = AgentNav.handle_key(draft, ?r, 0)
    end
  end

  describe "chat keys owned by the mode FSM" do
    test "leader, command line, eval, and search entry keys reach the mode FSM" do
      state = make_state(focus: :chat)

      for {cp, mods} <- [{?\s, 0}, {?:, 0}, {?:, @alt}, {?/, 0}, {?n, 0}, {?N, 0}] do
        assert {:passthrough, ^state} = AgentNav.handle_key(state, cp, mods)
      end
    end

    test "an open command line receives every key, including chat navigation keys" do
      state = make_state(focus: :chat)

      command_line = %{
        state
        | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :command)
      }

      for {cp, mods} <- [{?j, 0}, {?q, 0}, {?x, 0}, {13, 0}] do
        assert {:passthrough, ^command_line} = AgentNav.handle_key(command_line, cp, mods)
      end
    end
  end
end
