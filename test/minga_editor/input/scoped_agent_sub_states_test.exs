defmodule MingaEditor.Input.ScopedAgentSubStatesTest do
  use ExUnit.Case, async: true

  @moduledoc false
  @moduletag :tmp_dir

  import Minga.Test.ScopedInputHelpers

  alias MingaAgent.ToolApproval.Preview, as: ApprovalPreview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.View.Preview

  describe "agent scope — tool approval sub-state" do
    setup do
      state = base_state(keymap_scope: :agent, agentic_active: true)

      approval =
        PendingApproval.new(
          self(),
          Public.new(
            Target.new("scoped-fixture", "admitted-request", "tc_123"),
            "write_file",
            %{"path" => "/tmp/test.txt"},
            ApprovalPreview.new(:args, "", [])
          )
        )

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_state(
          state,
          AgentState.set_pending_approval(
            MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state),
            approval
          )
        )

      {:ok, state: state}
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

  test "returning from Review resumes the retained draft before the next character" do
    state =
      base_state(keymap_scope: :agent, agentic_active: true, input_focused: true)
      |> MingaEditor.Commands.Agent.scope_focus_input()
      |> MingaEditor.Commands.Agent.input_paste("Retained draft")

    ui =
      state.workspace.agent_ui
      |> MingaEditor.Agent.UIState.replace_preview(
        Preview.set_diff(Preview.new(), DiffReview.new("checkout.ex", "before", "after"))
      )
      |> MingaEditor.Agent.UIState.set_focus(:file_viewer)

    state =
      state
      |> MingaEditor.Shell.Traditional.Workflow.install_agent_ui(ui)
      |> MingaEditor.Commands.Agent.return_to_chat()

    assert {:handled, state} = walk_surface_handlers(state, ?z, 0)

    assert MingaEditor.Agent.PromptBuffer.input_text(state.workspace.agent_ui.panel) ==
             "Retained draftz"
  end

  test "prompt arrows preserve text and route the next shifted character to the prompt" do
    routes = [
      {MingaEditor.Input.Scoped, false},
      {MingaEditor.Input.AgentPanel, true},
      {:stack, false},
      {:stack, true}
    ]

    for {route, visible} <- routes, left <- [57_350, 0xF702], modifiers <- [0, 1] do
      state =
        base_state(
          keymap_scope: :agent,
          agentic_active: true,
          input_focused: true,
          panel_visible: visible
        )
        |> MingaEditor.Commands.Agent.scope_focus_input()
        |> MingaEditor.Commands.Agent.input_paste("abcd")

      real_buffer = state.workspace.buffers.active
      real_before = {Minga.Buffer.content(real_buffer), Minga.Buffer.cursor(real_buffer)}
      prompt = state.workspace.agent_ui.panel.prompt_buffer

      handlers =
        case route do
          :stack -> MingaEditor.Input.surface_handlers(state)
          module -> [module]
        end

      dispatch = fn state, cp, mods ->
        Enum.reduce_while(handlers, {:passthrough, state}, fn handler, {_, current} ->
          case handler.handle_key(current, cp, mods) do
            {:handled, updated} -> {:halt, {:handled, updated}}
            {:passthrough, updated} -> {:cont, {:passthrough, updated}}
          end
        end)
      end

      assert {:handled, state} = dispatch.(state, left, modifiers)
      assert {:handled, state} = dispatch.(state, left, modifiers)
      assert Minga.Buffer.content(prompt) == "abcd"
      assert Minga.Buffer.cursor(prompt) == {0, 2}
      assert Minga.Editing.mode(state) == :insert
      refute Minga.Editing.selecting?(state)

      assert {:handled, state} = dispatch.(state, ?X, 1)
      assert Minga.Buffer.content(prompt) == "abXcd"
      assert state.workspace.buffers.active == real_buffer
      assert {Minga.Buffer.content(real_buffer), Minga.Buffer.cursor(real_buffer)} == real_before
    end
  end

  test "CUA global save and quit remain reachable while a full-workspace draft is focused" do
    events = Module.concat(__MODULE__, "ShortcutEvents#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :duplicate, name: events}, id: events)
    options = start_supervised!({Minga.Config.Options, name: nil, events_registry: events})
    {:ok, true} = Minga.Config.Options.set(options, :confirm_quit, true)

    for {key, notice} <- [
          {?s, "No file name"},
          {?q, "Modified buffers exist. Really quit? (y/n)"}
        ] do
      state =
        base_state(keymap_scope: :agent, agentic_active: true, input_focused: true)
        |> MingaEditor.Commands.Agent.scope_focus_input()
        |> MingaEditor.Commands.Agent.input_paste("Retained draft")

      state = %{
        state
        | interaction:
            MingaEditor.State.Interaction.new(editing_model: :cua, options_server: options)
      }

      real_buffer = state.workspace.buffers.active
      Minga.Buffer.insert_text(real_buffer, "changed")

      result =
        Enum.reduce_while(
          MingaEditor.Input.surface_handlers(state),
          {:passthrough, state},
          fn handler, {_, current} ->
            case handler.handle_key(current, key, 0x02) do
              {:handled, updated} -> {:halt, {:handled, updated}}
              {:passthrough, updated} -> {:cont, {:passthrough, updated}}
            end
          end
        )

      assert {:handled, updated} = result
      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(updated) =~ notice

      assert MingaEditor.Agent.PromptBuffer.input_text(updated.workspace.agent_ui.panel) ==
               "Retained draft"

      assert updated.workspace.buffers.active == real_buffer
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
