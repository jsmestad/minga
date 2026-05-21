defmodule MingaEditor.Commands.VisualTextObjectTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Mode.VisualState
  alias MingaEditor.Commands.Visual
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias MingaEditor.Session.State, as: SessionState

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content})
  end

  defp build_state(buf, anchor \\ {0, 0}) do
    state = %EditorState{
      port_manager: nil,
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %MingaEditor.State.Buffers{active: buf, list: [buf]}
      }
    }

    EditorState.transition_mode(state, :visual, %VisualState{
      visual_anchor: anchor,
      visual_type: :char
    })
  end

  describe "visual paragraph and sentence text objects" do
    test "vip selects the current paragraph range as linewise" do
      buf = start_buffer("one\ntwo\n\nthree")
      BufferProcess.move_to(buf, {1, 1})
      state = build_state(buf)

      new_state = Visual.execute(state, {:visual_text_object, :inner, :paragraph})

      assert new_state.workspace.editing.mode_state.visual_anchor == {0, 0}
      assert new_state.workspace.editing.mode_state.visual_type == :line
      assert BufferProcess.cursor(buf) == {1, 2}
    end

    test "vap selects the paragraph plus trailing blank line" do
      buf = start_buffer("one\ntwo\n\nthree")
      BufferProcess.move_to(buf, {0, 1})
      state = build_state(buf)

      new_state = Visual.execute(state, {:visual_text_object, :around, :paragraph})

      assert new_state.workspace.editing.mode_state.visual_anchor == {0, 0}
      assert new_state.workspace.editing.mode_state.visual_type == :line
      assert BufferProcess.cursor(buf) == {2, 0}
    end

    test "vis selects the current sentence range" do
      buf = start_buffer("First. Second sentence!")
      BufferProcess.move_to(buf, {0, 10})
      state = build_state(buf)

      new_state = Visual.execute(state, {:visual_text_object, :inner, :sentence})

      assert new_state.workspace.editing.mode_state.visual_anchor == {0, 7}
      assert BufferProcess.cursor(buf) == {0, 22}
    end

    test "vas selects the sentence plus trailing whitespace" do
      buf = start_buffer("Hello.   Bye.")
      BufferProcess.move_to(buf, {0, 1})
      state = build_state(buf)

      new_state = Visual.execute(state, {:visual_text_object, :around, :sentence})

      assert new_state.workspace.editing.mode_state.visual_anchor == {0, 0}
      assert BufferProcess.cursor(buf) == {0, 8}
    end

    test "vas on whitespace selects the following sentence" do
      buf = start_buffer("Hello.   Bye.")
      BufferProcess.move_to(buf, {0, 7})
      state = build_state(buf)

      new_state = Visual.execute(state, {:visual_text_object, :around, :sentence})

      assert new_state.workspace.editing.mode_state.visual_anchor == {0, 6}
      assert BufferProcess.cursor(buf) == {0, 12}
    end

    test "vip then delete removes whole lines linewise" do
      buf = start_buffer("one\ntwo\n\nthree")
      BufferProcess.move_to(buf, {1, 1})
      state = build_state(buf)

      selected = Visual.execute(state, {:visual_text_object, :inner, :paragraph})
      new_state = Visual.execute(selected, :delete_visual_selection)

      assert BufferProcess.content(buf) == "\nthree"

      assert MingaEditor.State.Registers.get(new_state.workspace.editing.reg, "") ==
               {"one\ntwo\n", :linewise}
    end
  end
end
