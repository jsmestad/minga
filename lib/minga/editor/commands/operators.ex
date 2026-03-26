defmodule Minga.Editor.Commands.Operators do
  @moduledoc """
  Operator commands: delete/change/yank with motions, text objects, and
  line-wise variants (dd/yy/cc/S).
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  @command_specs [
    {:delete_line, "Delete current line", true},
    {:change_line, "Change current line", true},
    {:yank_line, "Yank current line", true}
  ]

  @spec execute(state(), Mode.command()) :: state()

  # ── Operator + motion ─────────────────────────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:delete_motion, motion}) do
    if read_only?(buf),
      do: read_only_msg(state),
      else: Helpers.apply_operator_motion(buf, state, motion, :delete)
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:change_motion, motion}) do
    if read_only?(buf),
      do: read_only_msg(state),
      else: Helpers.apply_operator_motion(buf, state, motion, :delete)
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:yank_motion, motion}) do
    Helpers.apply_operator_motion(buf, state, motion, :yank)
  end

  # ── Line-wise operators (dd / yy / cc / S) ────────────────────────────────

  def execute(%{workspace: %{buffers: %{active: _buf}}} = state, :delete_line) do
    execute(state, {:delete_lines_counted, 1})
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:delete_lines_counted, count})
      when is_integer(count) and count >= 1 do
    if read_only?(buf) do
      read_only_msg(state)
    else
      {line, _col} = Buffer.cursor(buf)
      total = Buffer.line_count(buf)
      end_line = min(line + count - 1, total - 1)
      yanked = Buffer.lines_content(buf, line, end_line)
      Buffer.delete_lines(buf, line, end_line)
      Helpers.put_register(state, yanked <> "\n", :delete, :linewise)
    end
  end

  def execute(%{workspace: %{buffers: %{active: _buf}}} = state, :change_line) do
    execute(state, {:change_lines_counted, 1})
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:change_lines_counted, count})
      when is_integer(count) and count >= 1 do
    if read_only?(buf) do
      read_only_msg(state)
    else
      {line, _col} = Buffer.cursor(buf)
      total = Buffer.line_count(buf)
      end_line = min(line + count - 1, total - 1)

      # Yank all lines first, then clear/delete
      yanked = Buffer.lines_content(buf, line, end_line)

      # Delete extra lines (all but the first), then clear the remaining one
      delete_trailing_lines(buf, line, end_line)
      {:ok, _} = Buffer.clear_line(buf, line)
      Helpers.put_register(state, yanked <> "\n", :delete, :linewise)
    end
  end

  def execute(%{workspace: %{buffers: %{active: _buf}}} = state, :yank_line) do
    execute(state, {:yank_lines_counted, 1})
  end

  def execute(%{workspace: %{buffers: %{active: buf}}} = state, {:yank_lines_counted, count})
      when is_integer(count) and count >= 1 do
    {line, _col} = Buffer.cursor(buf)
    total = Buffer.line_count(buf)
    end_line = min(line + count - 1, total - 1)
    yanked = Buffer.lines_content(buf, line, end_line)
    Helpers.put_register(state, yanked <> "\n", :yank, :linewise)
  end

  # ── Text object operators ─────────────────────────────────────────────────

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:delete_text_object, modifier, spec}
      )
      when is_pid(buf) do
    if read_only?(buf),
      do: read_only_msg(state),
      else: Helpers.apply_text_object(state, modifier, spec, :delete)
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:change_text_object, modifier, spec}
      )
      when is_pid(buf) do
    if read_only?(buf),
      do: read_only_msg(state),
      else: Helpers.apply_text_object(state, modifier, spec, :delete)
  end

  def execute(
        %{workspace: %{buffers: %{active: buf}}} = state,
        {:yank_text_object, modifier, spec}
      )
      when is_pid(buf) do
    Helpers.apply_text_object(state, modifier, spec, :yank)
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec delete_trailing_lines(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  defp delete_trailing_lines(_buf, same, same), do: :ok

  defp delete_trailing_lines(buf, start_line, end_line) do
    Buffer.delete_lines(buf, start_line + 1, end_line)
    :ok
  end

  @spec read_only?(pid()) :: boolean()
  defp read_only?(buf), do: Buffer.read_only?(buf)

  @spec read_only_msg(state()) :: state()
  defp read_only_msg(state), do: EditorState.set_status(state, "Buffer is read-only")

  @impl Minga.Command.Provider
  def __commands__ do
    Enum.map(@command_specs, fn {name, desc, requires_buffer} ->
      %Minga.Command{
        name: name,
        description: desc,
        requires_buffer: requires_buffer,
        execute: fn state -> execute(state, name) end
      }
    end)
  end
end
