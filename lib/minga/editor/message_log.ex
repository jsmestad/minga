defmodule Minga.Editor.MessageLog do
  @moduledoc """
  Writes to the `*Messages*` buffer with timestamp prefix and line trimming.

  Extracted from `Minga.Editor` to reduce GenServer module size.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState

  @max_lines 1000

  @doc """
  Appends a timestamped message to the `*Messages*` buffer.

  No-op if the messages buffer isn't available. Trims the buffer
  to `#{@max_lines}` lines when it grows too large.
  """
  @spec log(EditorState.t(), String.t()) :: EditorState.t()
  def log(%{buffers: %{messages: nil}} = state, _text), do: state

  def log(%{buffers: %{messages: buf}} = state, text) do
    time = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    BufferServer.append(buf, "[#{time}] #{text}\n")
    maybe_trim(buf)
    state
  end

  @doc """
  Returns the appropriate log prefix for the frontend type.
  """
  @spec frontend_prefix(EditorState.t()) :: String.t()
  def frontend_prefix(%{capabilities: %{frontend_type: :native_gui}}), do: "GUI"
  def frontend_prefix(_state), do: "ZIG"

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
