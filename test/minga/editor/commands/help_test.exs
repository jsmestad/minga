defmodule Minga.Editor.Commands.HelpTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Help
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.Viewport
  alias Minga.Mode

  # ── Test helpers ──────────────────────────────────────────────────────────────

  defp build_state do
    # Start a minimal buffer so add_buffer works
    {:ok, buf} =
      DynamicSupervisor.start_child(
        Minga.Buffer.Supervisor,
        {BufferServer, content: "hello", buffer_name: "test.txt"}
      )

    %EditorState{
      port_manager: nil,
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      mode: :normal,
      mode_state: Mode.initial_state(),
      buf: %Buffers{buffer: buf, buffers: [buf]}
    }
  end

  # ── Tests ─────────────────────────────────────────────────────────────────────

  describe "describe_key_result" do
    test "creates *Help* buffer with key description" do
      state = build_state()
      result = Help.execute(state, {:describe_key_result, "j", :move_down, "Move cursor down"})

      assert result.buf.help_buffer != nil
      assert Process.alive?(result.buf.help_buffer)

      content = BufferServer.content(result.buf.help_buffer)
      assert content =~ "Key:         j"
      assert content =~ "Command:     move_down"
      assert content =~ "Description: Move cursor down"
    end

    test "switches to *Help* buffer after describing" do
      state = build_state()
      result = Help.execute(state, {:describe_key_result, "SPC f f", :find_file, "Find file"})

      assert result.buf.buffer == result.buf.help_buffer
    end

    test "reuses existing *Help* buffer on subsequent calls" do
      state = build_state()
      result1 = Help.execute(state, {:describe_key_result, "j", :move_down, "Move cursor down"})
      help_pid = result1.buf.help_buffer

      result2 =
        Help.execute(result1, {:describe_key_result, "k", :move_up, "Move cursor up"})

      assert result2.buf.help_buffer == help_pid

      content = BufferServer.content(help_pid)
      assert content =~ "Command:     move_up"
      refute content =~ "Command:     move_down"
    end

    test "clears status message" do
      state = %{build_state() | status_msg: "Press key to describe:"}
      result = Help.execute(state, {:describe_key_result, "j", :move_down, "Move cursor down"})

      assert result.status_msg == nil
    end
  end

  describe "describe_key_not_found" do
    test "shows 'Key not bound' in *Help* buffer" do
      state = build_state()
      result = Help.execute(state, {:describe_key_not_found, "z"})

      content = BufferServer.content(result.buf.help_buffer)
      assert content =~ "Key not bound: z"
    end
  end

  describe "*Help* buffer properties" do
    test "help buffer is read-only" do
      state = build_state()
      result = Help.execute(state, {:describe_key_result, "j", :move_down, "Move cursor down"})

      assert BufferServer.read_only?(result.buf.help_buffer)
    end
  end
end
