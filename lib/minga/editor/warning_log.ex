defmodule Minga.Editor.WarningLog do
  @moduledoc """
  Writes to the `*Warnings*` buffer with timestamp prefix and line trimming.

  Mirrors `Minga.Editor.MessageLog` but targets the `*Warnings*` buffer,
  which only receives warning- and error-level log events.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState

  @max_lines 500

  @doc """
  Appends a timestamped warning/error message to the `*Warnings*` buffer.

  No-op if the warnings buffer isn't available. Trims the buffer
  to `#{@max_lines}` lines when it grows too large.
  """
  @spec log(EditorState.t(), String.t()) :: EditorState.t()
  def log(%{buffers: %{warnings: nil}} = state, _text), do: state

  def log(%{buffers: %{warnings: buf}} = state, text) do
    time = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    BufferServer.append(buf, "[#{time}] #{text}\n")
    maybe_trim(buf)
    state
  end

  @doc """
  Returns the line count in the `*Warnings*` buffer, or 0 if unavailable.
  """
  @spec line_count(EditorState.t()) :: non_neg_integer()
  def line_count(%{buffers: %{warnings: nil}}), do: 0

  def line_count(%{buffers: %{warnings: buf}}) do
    BufferServer.line_count(buf)
  end

  @spec maybe_trim(pid()) :: :ok
  defp maybe_trim(buf) do
    line_count = BufferServer.line_count(buf)

    if line_count > @max_lines do
      excess = line_count - @max_lines
      content = BufferServer.content(buf)
      lines = String.split(content, "\n")
      trimmed = lines |> Enum.drop(excess) |> Enum.join("\n")

      :sys.replace_state(buf, fn s ->
        %{s | document: Document.new(trimmed)}
      end)
    end

    :ok
  end
end
