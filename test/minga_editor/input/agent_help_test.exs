defmodule MingaEditor.Input.AgentHelpTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.FocusTree
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.Input.AgentHelp
  alias MingaEditor.Input.Router
  alias MingaEditor.Layout
  alias MingaEditor.Layout.SurfaceRegistry
  alias MingaEditor.PickerUI
  alias MingaEditor.RenderModel.UI.AgentHelpBuilder
  alias MingaEditor.RenderPipeline.Input, as: RenderInput
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State.Render
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Picker.CommandSource
  alias MingaEditor.Window

  @draft "Keep this draft while reading Help."

  test "Escape and question mark close Help without changing the covered editing context" do
    for mode <- [:insert, :normal], key <- [27, ??] do
      {state, prompt} = help_state(mode)
      updated = Router.route_key(state, key, 0)

      refute updated.workspace.agent_ui.view.help_visible
      assert updated.workspace.agent_ui.panel == state.workspace.agent_ui.panel
      assert updated.workspace.editing == state.workspace.editing
      assert updated.workspace.windows == state.workspace.windows
      assert Minga.Buffer.content(prompt) == @draft
    end
  end

  test "covered typing, submission and paste cannot edit or submit the draft" do
    {state, prompt} = help_state(:insert)

    for key <- [?x, 13] do
      updated = Router.route_key(state, key, 0)
      assert updated.workspace.agent_ui == state.workspace.agent_ui
      assert updated.workspace.editing == state.workspace.editing
    end

    updated = Router.route_paste(state, "Unrelated pasted text")
    assert updated.workspace.agent_ui == state.workspace.agent_ui
    assert Minga.Buffer.content(prompt) == @draft

    hidden = AgentCommands.scope_dismiss_help(state)
    assert {:passthrough, ^hidden} = AgentHelp.handle_key(hidden, ?x, 0)
    assert {:passthrough, ^hidden} = AgentHelp.handle_paste(hidden, "text")
  end

  test "named Help controls work over Review without replacing its source, position or draft" do
    {state, prompt} = help_state(:insert)

    review =
      DiffReview.from_fork_snapshot("selected.ex", {self(), 2, 1}, [
        {:conflict, ["agent"], ["human"], []}
      ])

    preview = Preview.set_diff(Preview.new(), review)

    ui =
      state.workspace.agent_ui
      |> UIState.replace_preview(preview)
      |> UIState.set_focus(:file_viewer)
      |> UIState.dismiss_help()

    state = Workflow.install_agent_ui(state, ui)
    opened = GuiActionHandler.dispatch(state, {:execute_command, "agent_toggle_help"})

    # Help over a review leads with its keys in the active editing model.
    assert %{visible?: true, groups: [{"Diff Review", review_keys} | _]} =
             AgentHelpBuilder.build(Context.from_editor_state(opened))

    assert {"y", "Accept hunk (Use Agent version)"} in review_keys
    assert {"x", "Reject hunk (Keep mine)"} in review_keys

    assert opened.workspace.windows == state.workspace.windows
    assert opened.workspace.agent_ui.view.preview == preview

    closed = GuiActionHandler.dispatch(opened, {:execute_command, "agent_dismiss_help"})
    assert closed.workspace.agent_ui == state.workspace.agent_ui
    assert AgentCommands.scope_dismiss_help(closed) == closed
    assert Minga.Buffer.content(prompt) == @draft
  end

  test "Help placement covers only the active fitted pane and yields to the picker" do
    {state, _prompt} = help_state(:normal)
    id = state.workspace.windows.active
    rect = {2, 4, 72, 18}

    layout = %Layout{
      terminal: {0, 0, 80, 24},
      editor_area: {1, 0, 80, 21},
      window_layouts: %{id => %{total: {1, 0, 80, 21}, content: rect}},
      status_bar: {22, 0, 80, 1},
      minibuffer: {23, 0, 80, 1}
    }

    state = %{state | render: Render.stage_layout(state.render, layout)}

    for source <- [state, RenderInput.from_editor_state(state)] do
      tree = FocusTree.from_state(source)
      assert %{content_type: :agent_help} = FocusTree.hit_test(tree, 2, 4)
      refute FocusTree.hit_test(tree, 22, 4).content_type == :agent_help
      assert SurfaceRegistry.rect_for_in(SurfaceRegistry.from_tree(tree), :agent_help) == rect
    end

    picker = PickerUI.open(state, CommandSource)
    refute Enum.any?(SurfaceRegistry.placements(picker), &(&1.surface_id == :agent_help))
  end

  defp help_state(mode) do
    prompt = start_supervised!({Minga.Buffer, content: @draft}, id: {:help_prompt, make_ref()})

    ui = %UIState{
      panel: %UIState.Panel{input_focused: true, prompt_buffer: prompt},
      view: %UIState.View{help_visible: true}
    }

    state = TestHelpers.base_state(backend: :gui) |> Workflow.install_agent_ui(ui)
    id = state.workspace.windows.active

    windows =
      Windows.replace_window(state.workspace.windows, id, Window.new_agent_chat(id, 24, 80))

    workspace =
      state.workspace
      |> SessionState.set_windows(windows)
      |> SessionState.transition_mode(mode)

    {%{state | workspace: workspace}, prompt}
  end
end
