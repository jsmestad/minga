defmodule Minga.Editor.Commands.Operators do
  @moduledoc """
  Operator commands: delete/change/yank with motions, text objects, and
  line-wise variants (dd/yy/cc/S).
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  @spec execute(state(), Mode.command()) :: state()

  # ── Operator + motion ─────────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, {:delete_motion, motion}) do
    Helpers.apply_operator_motion(buf, state, motion, :delete)
  end

  def execute(%{buffer: buf} = state, {:change_motion, motion}) do
    Helpers.apply_operator_motion(buf, state, motion, :delete)
  end

  def execute(%{buffer: buf} = state, {:yank_motion, motion}) do
    Helpers.apply_operator_motion(buf, state, motion, :yank)
  end

  # ── Line-wise operators (dd / yy / cc / S) ────────────────────────────────

  def execute(%{buffer: buf} = state, :delete_line) do
    {line, _col} = BufferServer.cursor(buf)
    yanked = BufferServer.get_lines_content(buf, line, line)
    BufferServer.delete_lines(buf, line, line)
    Helpers.put_register(state, yanked <> "\n", :delete)
  end

  def execute(%{buffer: buf} = state, :change_line) do
    {line, _col} = BufferServer.cursor(buf)
    {:ok, yanked} = BufferServer.clear_line(buf, line)
    Helpers.put_register(state, yanked <> "\n", :delete)
  end

  def execute(%{buffer: buf} = state, :yank_line) do
    {line, _col} = BufferServer.cursor(buf)
    yanked = BufferServer.get_lines_content(buf, line, line)
    Helpers.put_register(state, yanked <> "\n", :yank)
  end

  # ── Text object operators ─────────────────────────────────────────────────

  def execute(%{buffer: buf} = state, {:delete_text_object, modifier, spec}) when is_pid(buf) do
    Helpers.apply_text_object(state, modifier, spec, :delete)
  end

  def execute(%{buffer: buf} = state, {:change_text_object, modifier, spec}) when is_pid(buf) do
    Helpers.apply_text_object(state, modifier, spec, :delete)
  end

  def execute(%{buffer: buf} = state, {:yank_text_object, modifier, spec}) when is_pid(buf) do
    Helpers.apply_text_object(state, modifier, spec, :yank)
  end
end
