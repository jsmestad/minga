defmodule MingaEditor.Input.AgentPanelNavTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Scroll
  alias Minga.Keymap.Active, as: KeymapActive
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Input.AgentPanel
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.Viewport

  defp walk_surface_handlers(state, cp, mods) do
    Enum.reduce_while(MingaEditor.Input.surface_handlers(), {:passthrough, state}, fn handler,
                                                                                      {_, acc} ->
      case handler.handle_key(acc, cp, mods) do
        {:handled, new_state} -> {:halt, {:handled, new_state}}
        {:passthrough, new_state} -> {:cont, {:passthrough, new_state}}
      end
    end)
  end

  defp make_state do
    {:ok, prompt_buf} = BufferProcess.start_link(content: "")

    scroll =
      Scroll.new(5)
      |> Scroll.update_metrics(40, 10)

    base = UIState.new()

    agent_ui = %{
      base
      | panel: %{
          base.panel
          | visible: true,
            input_focused: false,
            prompt_buffer: prompt_buf,
            scroll: scroll
        }
    }

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        agent_ui: agent_ui
      },
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          MingaEditor.Shell.Traditional.State.replace_agent(
            %MingaEditor.Shell.Traditional.State{},
            %AgentState{}
          )
        ),
      interaction: %MingaEditor.State.Interaction{}
    }
  end

  describe "agent panel navigation mode" do
    test "j and k scroll the semantic transcript" do
      {:handled, down_state} = walk_surface_handlers(make_state(), ?j, 0)
      assert down_state.workspace.agent_ui.panel.scroll.offset == 6

      {:handled, up_state} = walk_surface_handlers(down_state, ?k, 0)
      assert up_state.workspace.agent_ui.panel.scroll.offset == 5
    end

    test "i focuses the input" do
      {:handled, new_state} = walk_surface_handlers(make_state(), ?i, 0)
      assert new_state.workspace.agent_ui.panel.input_focused
    end

    test "passthrough when panel not visible" do
      state = make_state()

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          %{state.workspace.agent_ui | panel: %{state.workspace.agent_ui.panel | visible: false}}
        )

      assert {:passthrough, _state} = AgentPanel.handle_key(state, ?j, 0)
    end

    test "q toggles the agent split" do
      {:handled, new_state} = walk_surface_handlers(make_state(), ?q, 0)
      refute is_nil(new_state)
    end
  end

  describe "leader sequence passthrough" do
    test "passes through when leader_node is set so commands run against real buffer" do
      state = make_state()
      leader_trie = KeymapActive.leader_trie()
      mode_state = %{state.workspace.editing.mode_state | leader_node: leader_trie}

      state = %{
        state
        | workspace: %{
            state.workspace
            | editing: %{state.workspace.editing | mode_state: mode_state}
          }
      }

      assert {:passthrough, _state} = AgentPanel.handle_key(state, ?N, 0)
    end
  end

  describe "agent panel input mode" do
    test "Escape unfocuses a normal-mode input without clearing the draft" do
      state =
        make_state()
        |> then(fn state ->
          ui =
            state.workspace.agent_ui
            |> MingaEditor.Agent.PromptBuffer.set_input_focused(true)
            |> MingaEditor.Agent.PromptBuffer.set_prompt_text("draft")

          MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, ui)
        end)

      {:handled, new_state} = walk_surface_handlers(state, 27, 0)

      refute new_state.workspace.agent_ui.panel.input_focused

      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) ==
               "draft"

      assert new_state.workspace.editing.mode == :normal
    end

    test "input mode intercepts printable chars" do
      state = make_state()

      agent_ui =
        UIState.replace_panel(
          state.workspace.agent_ui,
          %{state.workspace.agent_ui.panel | input_focused: true}
        )

      state = MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, agent_ui)

      workspace =
        MingaEditor.Session.State.transition_mode(
          state.workspace,
          :insert,
          state.workspace.editing.mode_state
        )

      state = %{state | workspace: workspace}

      {:handled, new_state} = walk_surface_handlers(state, ?a, 0)
      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) =~ "a"
    end
  end
end
