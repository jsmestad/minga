defmodule MingaEditor.Commands.CmdCopyCutTest do
  @moduledoc """
  Layer 0/1 command-state tests for :cmd_copy and :cmd_cut commands (macOS Cmd+C / Cmd+X menu actions).

  Verifies mode-aware behavior: visual selection when active, current line when not. Tests register writes and forced clipboard sync without a live Editor GenServer.
  """
  use ExUnit.Case, async: true

  import Hammox

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Editing
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Registers
  alias MingaEditor.Viewport
  alias MingaEditor.Session.State, as: SessionState
  alias Minga.Mode.VisualState

  setup :verify_on_exit!

  setup do
    test_pid = self()

    stub(Minga.Clipboard.Mock, :write, fn text ->
      send(test_pid, {:clipboard_written, text})
      :ok
    end)

    stub(Minga.Clipboard.Mock, :read, fn -> nil end)

    :ok
  end

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content})
  end

  defp build_state(buf) do
    %EditorState{
      port_manager: nil,
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %MingaEditor.State.Buffers{active: buf, list: [buf]}
      }
    }
  end

  defp with_visual_mode(state, _buf, anchor, visual_type) do
    ms = %VisualState{visual_anchor: anchor, visual_type: visual_type}
    editing = %{state.workspace.editing | mode: :visual, mode_state: ms}
    workspace = %{state.workspace | editing: editing}
    %{state | workspace: workspace}
  end

  defp register_entry(state, name \\ "") do
    Registers.get(state.workspace.editing.reg, name)
  end

  describe "cmd_copy in normal mode" do
    test "copies current line as linewise" do
      buf = start_buffer("hello\nworld\nfoo")
      state = build_state(buf)

      new_state = Editing.execute(state, :cmd_copy)

      assert register_entry(new_state) == {"hello\n", :linewise}
      assert BufferProcess.content(buf) == "hello\nworld\nfoo"
      assert_receive {:clipboard_written, "hello\n"}, 200
    end

    test "copies line at cursor position" do
      buf = start_buffer("aaa\nbbb\nccc")
      BufferProcess.move_to(buf, {1, 0})
      state = build_state(buf)

      new_state = Editing.execute(state, :cmd_copy)

      assert register_entry(new_state) == {"bbb\n", :linewise}
      assert BufferProcess.content(buf) == "aaa\nbbb\nccc"
      assert_receive {:clipboard_written, "bbb\n"}, 200
    end
  end

  describe "cmd_copy in visual mode" do
    test "copies charwise selection and transitions to normal mode" do
      buf = start_buffer("hello world")
      BufferProcess.move_to(buf, {0, 4})
      state = build_state(buf) |> with_visual_mode(buf, {0, 0}, :char)

      new_state = Editing.execute(state, :cmd_copy)

      assert register_entry(new_state) == {"hello", :charwise}
      assert BufferProcess.content(buf) == "hello world"
      assert new_state.workspace.editing.mode == :normal
      assert_receive {:clipboard_written, "hello"}, 200
    end

    test "copies linewise selection" do
      buf = start_buffer("aaa\nbbb\nccc")
      BufferProcess.move_to(buf, {1, 0})
      state = build_state(buf) |> with_visual_mode(buf, {0, 0}, :line)

      new_state = Editing.execute(state, :cmd_copy)

      assert register_entry(new_state) == {"aaa\nbbb\n", :linewise}
      assert BufferProcess.content(buf) == "aaa\nbbb\nccc"
    end

    test "copies charwise selection with reversed anchor (cursor before anchor)" do
      buf = start_buffer("hello world")
      BufferProcess.move_to(buf, {0, 0})
      state = build_state(buf) |> with_visual_mode(buf, {0, 4}, :char)

      new_state = Editing.execute(state, :cmd_copy)

      assert register_entry(new_state) == {"hello", :charwise}
      assert BufferProcess.content(buf) == "hello world"
    end

    test "cmd_copy from preserved visual selection copies selection text" do
      buf = start_buffer("selected text\nsecond line")
      BufferProcess.move_to(buf, {0, 7})
      state = build_state(buf) |> with_visual_mode(buf, {0, 0}, :char)

      new_state = Editing.execute(state, :cmd_copy)

      assert register_entry(new_state) == {"selected", :charwise}
      assert BufferProcess.content(buf) == "selected text\nsecond line"
      assert_receive {:clipboard_written, "selected"}, 200
    end

    test "copies linewise selection with cursor above anchor" do
      buf = start_buffer("aaa\nbbb\nccc")
      BufferProcess.move_to(buf, {0, 0})
      state = build_state(buf) |> with_visual_mode(buf, {2, 0}, :line)

      new_state = Editing.execute(state, :cmd_copy)

      assert register_entry(new_state) == {"aaa\nbbb\nccc\n", :linewise}
      assert BufferProcess.content(buf) == "aaa\nbbb\nccc"
    end
  end

  describe "cmd_cut in normal mode" do
    test "cuts current line as linewise" do
      buf = start_buffer("hello\nworld\nfoo")
      state = build_state(buf)

      new_state = Editing.execute(state, :cmd_cut)

      assert register_entry(new_state) == {"hello\n", :linewise}
      assert BufferProcess.content(buf) == "world\nfoo"
      assert_receive {:clipboard_written, "hello\n"}, 200
    end

    test "cuts line at cursor position" do
      buf = start_buffer("aaa\nbbb\nccc")
      BufferProcess.move_to(buf, {1, 0})
      state = build_state(buf)

      new_state = Editing.execute(state, :cmd_cut)

      assert register_entry(new_state) == {"bbb\n", :linewise}
      assert BufferProcess.content(buf) == "aaa\nccc"
      assert_receive {:clipboard_written, "bbb\n"}, 200
    end
  end

  describe "cmd_cut in visual mode" do
    test "deletes charwise selection and transitions to normal mode" do
      buf = start_buffer("hello world")
      BufferProcess.move_to(buf, {0, 4})
      state = build_state(buf) |> with_visual_mode(buf, {0, 0}, :char)

      new_state = Editing.execute(state, :cmd_cut)

      assert register_entry(new_state) == {"hello", :charwise}
      assert BufferProcess.content(buf) == " world"
      assert new_state.workspace.editing.mode == :normal
      assert_receive {:clipboard_written, "hello"}, 200
    end

    test "deletes linewise selection" do
      buf = start_buffer("aaa\nbbb\nccc")
      BufferProcess.move_to(buf, {1, 0})
      state = build_state(buf) |> with_visual_mode(buf, {0, 0}, :line)

      new_state = Editing.execute(state, :cmd_cut)

      assert register_entry(new_state) == {"aaa\nbbb\n", :linewise}
      assert BufferProcess.content(buf) == "ccc"
    end

    test "deletes charwise selection with reversed anchor" do
      buf = start_buffer("hello world")
      BufferProcess.move_to(buf, {0, 0})
      state = build_state(buf) |> with_visual_mode(buf, {0, 4}, :char)

      new_state = Editing.execute(state, :cmd_cut)

      assert register_entry(new_state) == {"hello", :charwise}
      assert BufferProcess.content(buf) == " world"
    end
  end

  describe "cmd_cut on read-only buffer" do
    test "normal mode does not modify buffer or sync clipboard" do
      buf = start_supervised!({BufferProcess, content: "protected content", read_only: true})
      state = build_state(buf)

      _new_state = Editing.execute(state, :cmd_cut)

      assert BufferProcess.content(buf) == "protected content"
      refute_receive {:clipboard_written, _}, 50
    end

    test "visual mode does not modify buffer or sync clipboard" do
      buf = start_supervised!({BufferProcess, content: "protected content", read_only: true})
      BufferProcess.move_to(buf, {0, 9})
      state = build_state(buf) |> with_visual_mode(buf, {0, 0}, :char)

      _new_state = Editing.execute(state, :cmd_cut)

      assert BufferProcess.content(buf) == "protected content"
      refute_receive {:clipboard_written, _}, 50
    end
  end
end
