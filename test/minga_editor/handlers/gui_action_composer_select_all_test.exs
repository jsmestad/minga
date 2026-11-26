defmodule MingaEditor.Handlers.GuiActionComposerSelectAllTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State.Windows
  alias MingaEditor.Window

  @draft "first line of the draft\nsecond line"

  describe "the Edit menu's Select All" do
    test "selects the whole draft when the composer has focus, and leaves the file alone" do
      for mode <- [:insert, :normal] do
        {state, prompt} = composer_state(mode, true)
        file = state.workspace.buffers.active
        file_cursor = Buffer.cursor(file)

        selected = GuiActionHandler.dispatch(state, {:execute_command, "select_all"})

        assert {mode, selected.workspace.editing.mode} == {mode, :visual}
        assert selected.workspace.editing.mode_state.visual_anchor == {0, 0}
        assert selected.workspace.editing.mode_state.visual_type == :line
        assert Buffer.cursor(prompt) == {1, 10}
        assert Buffer.content(prompt) == @draft

        # The file behind the conversation keeps its cursor and stays the active buffer.
        assert Buffer.cursor(file) == file_cursor
        assert selected.workspace.buffers.active == file
      end
    end

    test "selects the file when the composer does not have focus" do
      {state, prompt} = composer_state(:normal, false)
      file = state.workspace.buffers.active
      prompt_cursor = Buffer.cursor(prompt)

      selected = GuiActionHandler.dispatch(state, {:execute_command, "select_all"})

      assert selected.workspace.editing.mode == :visual
      assert Buffer.cursor(prompt) == prompt_cursor
      assert selected.workspace.buffers.active == file
    end
  end

  defp composer_state(mode, focused?) do
    prompt = start_supervised!({Buffer, content: @draft}, id: {:composer_prompt, make_ref()})
    ui = %UIState{panel: %UIState.Panel{input_focused: focused?, prompt_buffer: prompt}}

    state = TestHelpers.base_state(backend: :gui) |> Workflow.install_agent_ui(ui)
    id = state.workspace.windows.active

    windows =
      Windows.replace_window(state.workspace.windows, id, Window.new_agent_chat(id, 24, 80))

    workspace =
      state.workspace
      |> SessionState.set_windows(windows)
      |> SessionState.set_keymap_scope(:agent)
      |> SessionState.transition_mode(mode)

    {%{state | workspace: workspace}, prompt}
  end
end
