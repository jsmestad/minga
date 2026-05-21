defmodule MingaEditor.Commands.NoBufferTest do
  @moduledoc """
  Layer-1 contract: when no buffer is active, every command that requires a
  buffer returns state unchanged.
  """
  use ExUnit.Case, async: true

  alias MingaEditor.Commands
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Session.State, as: SessionState

  defp no_buffer_state do
    %EditorState{
      port_manager: nil,
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: nil, list: []},
        editing: VimState.new()
      }
    }
  end

  describe "Commands.execute/2 with no active buffer" do
    setup do
      {:ok, state: no_buffer_state()}
    end

    test "atom motion commands are no-ops", %{state: state} do
      for cmd <- [:move_left, :move_right, :move_up, :move_down] do
        assert Commands.execute(state, cmd) == state
      end
    end

    test "atom edit commands are no-ops", %{state: state} do
      for cmd <- [:undo, :redo, :paste, :paste_before, :join_lines] do
        assert Commands.execute(state, cmd) == state
      end
    end

    test "tuple commands are no-ops", %{state: state} do
      for cmd <- [
            {:insert_char, "x"},
            {:delete_chars_at, 1},
            {:delete_motion, :line_end},
            {:set_mark, "a"}
          ] do
        assert Commands.execute(state, cmd) == state
      end
    end

    test "search commands are no-ops", %{state: state} do
      for cmd <- [:search_buffer, :search_and_replace] do
        assert Commands.execute(state, cmd) == state
      end
    end
  end
end
