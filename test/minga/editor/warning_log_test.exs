defmodule Minga.Editor.WarningLogTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.Viewport
  alias Minga.Editor.WarningLog

  setup do
    {:ok, buf} =
      start_supervised(
        {BufferServer, content: "", buffer_name: "*Warnings*", read_only: true, unlisted: true}
      )

    state = %EditorState{
      port_manager: nil,
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      buffers: %Buffers{warnings: buf}
    }

    {:ok, state: state, buf: buf}
  end

  describe "log/2" do
    test "appends a timestamped message to the warnings buffer", %{state: state, buf: buf} do
      WarningLog.log(state, "test warning")
      content = BufferServer.content(buf)
      assert content =~ ~r/\[\d{2}:\d{2}:\d{2}\] test warning/
    end

    test "no-op when warnings buffer is nil" do
      state = %EditorState{
        port_manager: nil,
        viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
        buffers: %Buffers{warnings: nil}
      }

      # Should not crash
      assert WarningLog.log(state, "test") == state
    end

    test "multiple warnings are appended in order", %{state: state, buf: buf} do
      WarningLog.log(state, "first warning")
      WarningLog.log(state, "second warning")
      content = BufferServer.content(buf)
      assert content =~ "first warning"
      assert content =~ "second warning"

      lines = String.split(content, "\n", trim: true)
      first_idx = Enum.find_index(lines, &String.contains?(&1, "first warning"))
      second_idx = Enum.find_index(lines, &String.contains?(&1, "second warning"))
      assert first_idx < second_idx
    end
  end

  describe "line_count/1" do
    test "returns 0 when warnings buffer is nil" do
      state = %EditorState{
        port_manager: nil,
        viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
        buffers: %Buffers{warnings: nil}
      }

      assert WarningLog.line_count(state) == 0
    end

    test "returns the line count of the warnings buffer", %{state: state, buf: buf} do
      BufferServer.append(buf, "line 1\nline 2\nline 3\n")
      assert WarningLog.line_count(state) >= 3
    end
  end

  describe "trimming" do
    test "trims buffer when it exceeds max lines", %{state: state, buf: buf} do
      # Append more than 500 lines
      lines = Enum.map_join(1..510, "\n", fn i -> "warning #{i}" end)
      BufferServer.append(buf, lines <> "\n")

      # Logging one more should trigger the trim
      WarningLog.log(state, "final warning")

      line_count = BufferServer.line_count(buf)
      assert line_count <= 501
    end
  end
end
