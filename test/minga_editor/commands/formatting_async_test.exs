defmodule MingaEditor.Commands.FormattingAsyncTest do
  @moduledoc "Tests for async external formatter result application."
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Formatting
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  describe "apply_format_external_result/2" do
    test "applies formatted content when buffer version matches" do
      state = base_state("hello world\n")
      buf = state.workspace.buffers.active
      version = Buffer.version(buf)

      new_state =
        Formatting.apply_format_external_result(state, {:ok, "HELLO WORLD\n", buf, version})

      assert Buffer.content(buf) == "HELLO WORLD\n"
      assert new_state.shell_state.status_msg == "Formatted"
    end

    test "skips formatting when buffer version changed" do
      state = base_state("hello world\n")
      buf = state.workspace.buffers.active
      old_version = Buffer.version(buf)

      Buffer.replace_content(buf, "modified\n")

      new_state =
        Formatting.apply_format_external_result(state, {:ok, "STALE\n", buf, old_version})

      assert Buffer.content(buf) == "modified\n"
      assert new_state.shell_state.status_msg =~ "Buffer changed"
    end

    test "handles formatter error" do
      state = base_state("hello\n")

      new_state =
        Formatting.apply_format_external_result(state, {:error, "formatter exited with code 1"})

      assert new_state.shell_state.status_msg =~ "Format error"
    end

    test "preserves cursor position after formatting" do
      state = base_state("line one\nline two\nline three\n")
      buf = state.workspace.buffers.active
      Buffer.move_to(buf, {1, 3})
      version = Buffer.version(buf)

      new_state =
        Formatting.apply_format_external_result(
          state,
          {:ok, "LINE ONE\nLINE TWO\nLINE THREE\n", buf, version}
        )

      assert Buffer.content(buf) == "LINE ONE\nLINE TWO\nLINE THREE\n"
      {line, col} = Buffer.cursor(buf)
      assert line == 1
      assert col == 3
      assert new_state.shell_state.status_msg == "Formatted"
    end
  end

  defp base_state(content) do
    buffer = start_supervised!({BufferProcess, content: content}, id: {:buffer, make_ref()})

    workspace = %MingaEditor.Session.State{
      viewport: Viewport.new(24, 80),
      editing: VimState.new(),
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new(1, buffer, 24, 80)},
        active: 1,
        next_id: 2
      }
    }

    %EditorState{port_manager: self(), workspace: workspace}
  end
end
