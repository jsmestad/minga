defmodule Minga.Editor.ModeTransitions do
  @moduledoc """
  Mode state adjustments during vim mode transitions.

  When entering visual, command, eval, or search mode, the mode state
  struct needs initialization (e.g., capturing the cursor as a visual
  anchor, creating a CommandState). These are pure functions that
  transform mode state based on the old and new mode.
  """

  alias Minga.Buffer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode
  alias Minga.Mode.CommandState
  alias Minga.Mode.EvalState

  @doc """
  Adjusts mode_state when transitioning between modes.

  Handles visual anchor capture, CommandState/EvalState initialization,
  and search cursor preservation.
  """
  @spec adjust(Mode.state(), Mode.mode(), Mode.mode(), EditorState.t()) :: Mode.state()

  # Entering visual mode: capture cursor as selection anchor.
  def adjust(mode_state, old_mode, :visual, %{workspace: %{buffers: %{active: buf}}})
      when old_mode != :visual and is_pid(buf) do
    anchor = Buffer.cursor(buf)
    %{mode_state | visual_anchor: anchor}
  end

  # Entering command mode: ensure CommandState.
  def adjust(mode_state, old_mode, :command, _state) when old_mode != :command do
    case mode_state do
      %CommandState{} -> mode_state
      _ -> %CommandState{}
    end
  end

  # Entering eval mode: ensure EvalState.
  def adjust(mode_state, old_mode, :eval, _state) when old_mode != :eval do
    case mode_state do
      %EvalState{} -> mode_state
      _ -> %EvalState{}
    end
  end

  # Entering search mode: capture cursor for restore on Escape.
  def adjust(
        %Minga.Mode.SearchState{} = mode_state,
        old_mode,
        :search,
        %{workspace: %{buffers: %{active: buf}}}
      )
      when old_mode != :search and is_pid(buf) do
    cursor = Buffer.cursor(buf)
    %{mode_state | original_cursor: cursor}
  end

  # All other transitions: pass through.
  def adjust(mode_state, _old_mode, _new_mode, _state), do: mode_state
end
