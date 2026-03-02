defmodule Minga.Operator do
  @moduledoc """
  Operator functions for the Minga editor: delete, change, and yank.

  Each function takes a `Buffer.Server` PID and two positions, and applies
  the operator to the text between those positions.

  ## Position semantics

  All range functions use **inclusive** bounds — both `from` and `to` positions
  are included in the operation.  Positions are automatically normalised, so
  `from` may be greater than `to`.

  ## Return values

  * `delete/3` — `{:ok, :deleted}` after removing the range.
  * `change/3` — `{:ok, :changed}` after removing the range (caller should
    then switch to Insert mode).
  * `yank/3`  — `{:ok, yanked_text}` without modifying the buffer.

  ## Line-wise helpers

  `delete_line/2`, `change_line/2`, and `yank_line/2` operate on an entire
  line by index (zero-based).
  """

  alias Minga.Buffer.{GapBuffer, Server}

  @typedoc "A zero-indexed {line, col} cursor position."
  @type position :: GapBuffer.position()

  # ── Character-range operators ─────────────────────────────────────────────

  @doc """
  Deletes the text between `from` and `to` (inclusive) in the buffer managed
  by `server`.  Positions are automatically normalised.
  Returns `{:ok, :deleted}`.
  """
  @spec delete(GenServer.server(), position(), position()) :: {:ok, :deleted}
  def delete(server, from, to) do
    Server.delete_range(server, from, to)
    {:ok, :deleted}
  end

  @doc """
  Deletes the text between `from` and `to` (inclusive), just like `delete/3`.
  The caller is expected to transition to Insert mode afterward.
  Returns `{:ok, :changed}`.
  """
  @spec change(GenServer.server(), position(), position()) :: {:ok, :changed}
  def change(server, from, to) do
    Server.delete_range(server, from, to)
    {:ok, :changed}
  end

  @doc """
  Returns the text between `from` and `to` (inclusive) without modifying the buffer.
  Returns `{:ok, yanked_text}`.
  """
  @spec yank(GenServer.server(), position(), position()) :: {:ok, String.t()}
  def yank(server, from, to) do
    text = Server.get_range(server, from, to)
    {:ok, text}
  end

  # ── Line-wise operators ───────────────────────────────────────────────────

  @doc """
  Deletes the entire line at `line_index` (zero-based) from the buffer.

  If the buffer has more than one line, the trailing newline (or preceding
  newline for the last line) is also removed so no blank line is left.
  Returns `{:ok, :deleted}`.
  """
  @spec delete_line(GenServer.server(), non_neg_integer()) :: {:ok, :deleted}
  def delete_line(server, line_index) when is_integer(line_index) and line_index >= 0 do
    {from, to} = line_range(server, line_index)
    Server.delete_range(server, from, to)
    {:ok, :deleted}
  end

  @doc """
  Deletes the entire line at `line_index`, just like `delete_line/2`.
  The caller is expected to transition to Insert mode afterward.
  Returns `{:ok, :changed}`.
  """
  @spec change_line(GenServer.server(), non_neg_integer()) :: {:ok, :changed}
  def change_line(server, line_index) when is_integer(line_index) and line_index >= 0 do
    {from, to} = line_range(server, line_index)
    Server.delete_range(server, from, to)
    {:ok, :changed}
  end

  @doc """
  Returns the full text of the line at `line_index` (including newline separator
  where present) without modifying the buffer.
  Returns `{:ok, yanked_text}`.
  """
  @spec yank_line(GenServer.server(), non_neg_integer()) :: {:ok, String.t()}
  def yank_line(server, line_index) when is_integer(line_index) and line_index >= 0 do
    {from, to} = line_range(server, line_index)
    text = Server.get_range(server, from, to)
    {:ok, text}
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  # Returns {from_pos, to_pos} covering the entire line at `line_index`
  # using INCLUSIVE range semantics — both endpoints included.
  #
  # Positions use byte-indexed columns. The newline between line N and N+1
  # sits at byte_col == byte_size(lineN). Passing col == byte_size as the
  # inclusive end therefore includes the newline.
  @spec line_range(GenServer.server(), non_neg_integer()) :: {position(), position()}
  defp line_range(server, line_index) do
    total_lines = Server.line_count(server)
    line_text = Server.get_lines(server, line_index, 1) |> List.first() |> then(&(&1 || ""))
    line_len = byte_size(line_text)

    cond do
      # Only line in the buffer — delete from col 0 through last byte of last grapheme.
      # If the line is empty, delete_range handles it gracefully (delete_count clamped to 0).
      total_lines == 1 ->
        last_col = if line_len == 0, do: 0, else: GapBuffer.last_grapheme_byte_offset(line_text)
        {{0, 0}, {0, last_col}}

      # Last line — also consume the preceding newline so no orphan line remains.
      # The newline lives at byte_col == byte_size(prev_text) on the previous line.
      line_index >= total_lines - 1 ->
        prev_text =
          Server.get_lines(server, line_index - 1, 1)
          |> List.first()
          |> then(&(&1 || ""))

        prev_len = byte_size(prev_text)
        last_col = if line_len == 0, do: 0, else: GapBuffer.last_grapheme_byte_offset(line_text)
        {{line_index - 1, prev_len}, {line_index, last_col}}

      # Any other line — include the trailing newline using byte_col == byte_size(line).
      true ->
        {{line_index, 0}, {line_index, line_len}}
    end
  end
end
