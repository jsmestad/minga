defmodule Minga.Editor.MessageLog do
  @moduledoc """
  Writes to the `*Messages*` buffer with timestamp prefix and line trimming.

  This is the **unconditional tier** of the logging pipeline. Messages written
  here always appear in `*Messages*` regardless of log level settings. Use it
  for user-visible lifecycle events: file open, save, close, config reload, etc.

  The **filterable tier** is `Minga.Log`, which routes through per-subsystem
  log levels and is intended for diagnostic output (LSP traces, render timing,
  debug context). `Minga.Log` eventually calls back into this module via the
  `Minga.LoggerHandler`, but those messages are gated by subsystem log levels.

  Extracted from `Minga.Editor` to reduce GenServer module size.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Panel.MessageStore

  @max_lines 1000

  @doc """
  Appends a timestamped message to the `*Messages*` buffer and the
  structured MessageStore (for the GUI Messages tab).

  No-op if the messages buffer isn't available. Trims the buffer
  to `#{@max_lines}` lines when it grows too large.
  """
  @spec log(EditorState.t(), String.t()) :: EditorState.t()
  def log(state, text), do: log(state, text, nil)

  @doc """
  Appends a timestamped message with an explicit level override.

  When `level_override` is non-nil, it is used instead of parsing the prefix.
  Warning-level messages get a `[WARN]` prefix in the gap buffer for TUI visibility.
  """
  @spec log(EditorState.t(), String.t(), MessageStore.level() | nil) :: EditorState.t()
  def log(%{buffers: %{messages: nil}} = state, _text, _level), do: state

  def log(%{buffers: %{messages: buf}} = state, text, level_override) do
    # Parse prefix for subsystem detection (always) and level (when no override)
    {parsed_level, subsystem, _clean_text} = MessageStore.parse_prefix(text)
    level = level_override || parsed_level

    # Add [WARN]/[ERROR] prefix for TUI visibility when level is overridden
    display_text =
      case level_override do
        :warning -> "[WARN] #{text}"
        :error -> "[ERROR] #{text}"
        _ -> text
      end

    time = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    BufferServer.append(buf, "[#{time}] #{display_text}\n")
    maybe_trim(buf)

    # Dual-write: also append to the structured store for GUI rendering.
    %{state | message_store: MessageStore.append(state.message_store, text, level, subsystem)}
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
