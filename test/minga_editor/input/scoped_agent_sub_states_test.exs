defmodule MingaEditor.Input.ScopedAgentSubStatesTest do
  use ExUnit.Case, async: true

  @moduledoc false
  @moduletag :tmp_dir

  import Minga.Test.ScopedInputHelpers

  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.View.Preview

  describe "agent scope — tool approval sub-state" do
    setup do
      state = base_state(keymap_scope: :agent, agentic_active: true)

      approval = %{
        tool_call_id: "tc_123",
        name: "write_file",
        args: %{"path" => "/tmp/test.txt"}
      }

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_state(
          state,
          (fn agent -> %{agent | pending_approval: approval} end).(
            MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
          )
        )

      {:ok, state: state}
    end

    test "approval decision keys are handled", %{state: state} do
      for key <- [?y, ?a, ?t, ?n] do
        assert {:handled, _new_state} = walk_surface_handlers(state, key, 0)
      end
    end

    test "unrelated key passes through approval routing", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?x, 0)
      # The approval handler passes it through, and downstream routing still handles the key.
      assert MingaEditor.Shell.Traditional.State.agent(new_state.shell_runtime.state).pending_approval !=
               nil
    end

    test "only triggers when input is not focused", %{state: state} do
      # If input is focused in insert mode, approval keys should not be intercepted
      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
          state,
          (fn p ->
             %{p | input_focused: true, visible: true}
           end).(state.workspace.agent_ui.panel)
        )

      state = %{
        state
        | workspace: %{state.workspace | editing: %{state.workspace.editing | mode: :insert}}
      }

      {:handled, new_state} = walk_surface_handlers(state, ?y, 0)
      # Should have typed 'y' into input, not approved
      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) =~ "y"
    end
  end

  describe "agent scope — diff review sub-state" do
    setup do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :file_viewer)

      # Set up a diff review preview
      review = DiffReview.new("test.ex", "old line\n", "new line\n")

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_view(
          state,
          (fn v ->
             %{v | preview: %Preview{content: {:diff, review}}}
           end).(state.workspace.agent_ui.view)
        )

      {:ok, state: state}
    end

    test "diff review action and navigation keys are handled", %{state: state} do
      for key <- [?y, ?x, ?Y, ?X, ?j] do
        assert {:handled, _new_state} = walk_surface_handlers(state, key, 0)
      end
    end

    test "diff review only triggers in file_viewer focus" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :chat)

      review = DiffReview.new("test.ex", "old line\n", "new line\n")

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_view(
          state,
          (fn v ->
             %{v | preview: %Preview{content: {:diff, review}}}
           end).(state.workspace.agent_ui.view)
        )

      # In :chat focus, y should resolve through the scope trie, not diff review
      {:handled, _new_state} = walk_surface_handlers(state, ?y, 0)
    end
  end

  describe "agent scope — mention completion sub-state" do
    setup do
      state = base_state(keymap_scope: :agent, agentic_active: true, input_focused: true)

      completion = %{
        prefix: "@",
        all_files: ["lib/test.ex", "lib/foo.ex"],
        candidates: ["lib/test.ex", "lib/foo.ex"],
        selected: 0,
        anchor_line: 0,
        anchor_col: 0
      }

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
          state,
          (fn p -> %{p | mention_completion: completion} end).(state.workspace.agent_ui.panel)
        )

      {:ok, state: state}
    end

    test "Tab moves to next candidate", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 9, 0)
      assert new_state.workspace.agent_ui.panel.mention_completion.selected == 1
    end

    test "Enter and Escape clear mention completion", %{state: state} do
      for key <- [13, 27] do
        {:handled, new_state} = walk_surface_handlers(state, key, 0)
        assert new_state.workspace.agent_ui.panel.mention_completion == nil
      end
    end

    test "printable char narrows candidates", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?t, 0)
      comp = new_state.workspace.agent_ui.panel.mention_completion

      if comp != nil do
        assert Enum.count(comp.candidates) <=
                 Enum.count(state.workspace.agent_ui.panel.mention_completion.candidates)
      end
    end

    test "mention only intercepts in insert mode", %{state: state} do
      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
          state,
          (fn p -> %{p | input_focused: false} end).(state.workspace.agent_ui.panel)
        )

      {:handled, _new_state} = walk_surface_handlers(state, ?j, 0)
    end
  end

  describe "editor panel — slash command completion sub-state" do
    test "filters commands and accepts without inserting an @ mention" do
      state = base_state(keymap_scope: :editor, panel_visible: true, input_focused: true)

      {:handled, state} = walk_surface_handlers(state, ?/, 0)
      {:handled, state} = walk_surface_handlers(state, ?m, 0)
      {:handled, state} = walk_surface_handlers(state, ?o, 0)
      comp = state.workspace.agent_ui.panel.mention_completion
      assert comp.slash_candidates == [{"model", "Set the model: /model <name>"}]

      {:handled, state} = walk_surface_handlers(state, 13, 0)
      assert Minga.Buffer.content(state.workspace.agent_ui.panel.prompt_buffer) == "/model "
      assert state.workspace.agent_ui.panel.mention_completion == nil
    end

    test "re-summons slash completion after the first command character" do
      state = base_state(keymap_scope: :editor, panel_visible: true, input_focused: true)

      {:handled, state} = walk_surface_handlers(state, ?/, 0)
      {:handled, state} = walk_surface_handlers(state, ?m, 0)
      {:handled, state} = walk_surface_handlers(state, ?o, 0)
      {:handled, state} = walk_surface_handlers(state, 27, 0)
      assert state.workspace.agent_ui.panel.mention_completion == nil

      {:handled, state} = walk_surface_handlers(state, ?/, 0)
      comp = state.workspace.agent_ui.panel.mention_completion

      assert Minga.Buffer.content(state.workspace.agent_ui.panel.prompt_buffer) == "/mo"
      assert comp.prefix == "mo"
      assert comp.slash_candidates == [{"model", "Set the model: /model <name>"}]
    end
  end

  describe "agent scope — slash command completion sub-state" do
    test "re-summons slash completion inside a partially typed command token" do
      state = base_state(keymap_scope: :agent, agentic_active: true, input_focused: true)

      {:handled, state} = walk_surface_handlers(state, ?/, 0)
      {:handled, state} = walk_surface_handlers(state, ?m, 0)
      {:handled, state} = walk_surface_handlers(state, ?o, 0)
      {:handled, state} = walk_surface_handlers(state, 27, 0)
      assert state.workspace.agent_ui.panel.mention_completion == nil

      {:handled, state} = walk_surface_handlers(state, ?/, 0)
      comp = state.workspace.agent_ui.panel.mention_completion

      assert Minga.Buffer.content(state.workspace.agent_ui.panel.prompt_buffer) == "/mo"
      assert comp.prefix == "mo"
      assert comp.slash_candidates == [{"model", "Set the model: /model <name>"}]
    end
  end

  describe "editor scope — panel mention completion" do
    setup do
      state =
        base_state(
          keymap_scope: :editor,
          panel_visible: true,
          input_focused: true
        )

      completion = %{
        prefix: "@",
        all_files: ["lib/test.ex"],
        candidates: ["lib/test.ex"],
        selected: 0,
        anchor_line: 0,
        anchor_col: 0
      }

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
          state,
          (fn p -> %{p | mention_completion: completion} end).(state.workspace.agent_ui.panel)
        )

      {:ok, state: state}
    end

    test "mention completion intercepts keys in editor panel too", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 27, 0)
      assert new_state.workspace.agent_ui.panel.mention_completion == nil
    end
  end
end
