defmodule MingaEditor.UI.Panel.MessageStore do
  @moduledoc """
  Structured log entry store for the GUI Messages tab.

  Holds up to 1000 structured log entries with level, subsystem, timestamp,
  text, and optional file path. The GUI protocol encoder reads from this store
  to send incremental entries to the frontend.

  The TUI uses the `*Messages*` gap buffer, written by `MessagesBuffer`.
  Both are fed from `:log_message` event broadcasts via `Minga.Log`.
  """

  alias __MODULE__.Entry

  @max_entries 1000

  @type level :: :debug | :info | :warning | :error

  @type subsystem ::
          :editor | :lsp | :parser | :git | :render | :agent | :zig | :gui

  @type stream_instance :: 1..0xFFFF_FFFF

  @type t :: %__MODULE__{
          entries: [Entry.t()],
          next_id: pos_integer(),
          last_sent_id: non_neg_integer(),
          stream_instance: 0 | stream_instance()
        }

  defstruct entries: [],
            next_id: 1,
            last_sent_id: 0,
            stream_instance: 0

  @doc "Creates a message stream with a producer-assigned restart instance."
  @spec new() :: t()
  def new do
    %__MODULE__{stream_instance: next_stream_instance()}
  end

  @doc "Ensures a raw struct has a producer-assigned restart instance."
  @spec ensure_stream_instance(t()) :: t()
  def ensure_stream_instance(%__MODULE__{stream_instance: instance} = store)
      when instance in 1..0xFFFF_FFFF do
    store
  end

  def ensure_stream_instance(%__MODULE__{} = store) do
    %{store | stream_instance: next_stream_instance()}
  end

  @doc "Append a structured log entry. Trims to #{@max_entries} entries."
  @spec append(t(), String.t(), level(), subsystem()) :: t()
  def append(%__MODULE__{} = store, text, level \\ :info, subsystem \\ :editor) do
    store = ensure_stream_instance(store)
    file_path = extract_file_path(text)

    entry = %Entry{
      id: store.next_id,
      level: level,
      subsystem: subsystem,
      timestamp: NaiveDateTime.utc_now(),
      text: text,
      file_path: file_path
    }

    entries = store.entries ++ [entry]

    trimmed =
      if length(entries) > @max_entries,
        do: Enum.drop(entries, length(entries) - @max_entries),
        else: entries

    %{store | entries: trimmed, next_id: store.next_id + 1}
  end

  @doc "Returns entries with id > `since_id` (for incremental protocol sends)."
  @spec entries_since(t(), non_neg_integer()) :: [Entry.t()]
  def entries_since(%__MODULE__{entries: entries}, since_id) do
    Enum.filter(entries, fn e -> e.id > since_id end)
  end

  @doc "Mark the last sent ID (called after protocol encode)."
  @spec mark_sent(t(), non_neg_integer()) :: t()
  def mark_sent(%__MODULE__{} = store, id) do
    %{store | last_sent_id: id}
  end

  @doc "Resets the consumer send cursor after frontend state is lost."
  @spec reset_sent_cursor(t()) :: t()
  def reset_sent_cursor(%__MODULE__{} = store), do: %{store | last_sent_id: 0}

  @doc "Merges the producer's sent cursor without replacing newer entries."
  @spec merge_sent_cursor(t(), t()) :: t()
  def merge_sent_cursor(
        %__MODULE__{stream_instance: instance} = current,
        %__MODULE__{
          stream_instance: instance
        } = emitted
      ) do
    %{current | last_sent_id: max(current.last_sent_id, emitted.last_sent_id)}
  end

  def merge_sent_cursor(%__MODULE__{} = current, %__MODULE__{}), do: current

  @doc "Parse level and subsystem from a log message text prefix."
  @spec parse_prefix(String.t()) :: {level(), subsystem(), String.t()}
  def parse_prefix(text) do
    cond_parse(text)
  end

  # ── File path extraction ──

  @file_path_patterns [
    # "Opened: lib/minga/editor.ex"
    ~r/(?:Opened|Saved|Closed|Created):\s+(.+)/,
    # "External change detected: lib/minga/editor.ex"
    ~r/External change detected:\s+(.+)/,
    # "Format on save: lib/minga/editor.ex"
    ~r/Format on save:\s+(.+)/
  ]

  @spec extract_file_path(String.t()) :: String.t() | nil
  defp extract_file_path(text) do
    Enum.find_value(@file_path_patterns, fn pattern ->
      case Regex.run(pattern, text) do
        [_, path] -> String.trim(path)
        _ -> nil
      end
    end)
  end

  # ── Prefix parsing (multi-clause instead of cond) ──

  @spec cond_parse(String.t()) :: {level(), subsystem(), String.t()}
  defp cond_parse("[ZIG/err] " <> rest), do: {:error, :zig, rest}
  defp cond_parse("[ZIG/warn] " <> rest), do: {:warning, :zig, rest}
  defp cond_parse("[ZIG/info] " <> rest), do: {:info, :zig, rest}
  defp cond_parse("[ZIG/debug] " <> rest), do: {:debug, :zig, rest}
  defp cond_parse("[GUI/err] " <> rest), do: {:error, :gui, rest}
  defp cond_parse("[GUI/warn] " <> rest), do: {:warning, :gui, rest}
  defp cond_parse("[GUI/info] " <> rest), do: {:info, :gui, rest}
  defp cond_parse("[GUI/debug] " <> rest), do: {:debug, :gui, rest}
  defp cond_parse("[PARSER/err] " <> rest), do: {:error, :parser, rest}
  defp cond_parse("[PARSER/warn] " <> rest), do: {:warning, :parser, rest}
  defp cond_parse("[PARSER/info] " <> rest), do: {:info, :parser, rest}
  defp cond_parse("[PARSER/debug] " <> rest), do: {:debug, :parser, rest}
  defp cond_parse("[LSP] " <> rest), do: {:info, :lsp, rest}

  defp cond_parse("[render:" <> _ = text) do
    {:debug, :render, text}
  end

  defp cond_parse("[agent] " <> rest), do: {:info, :agent, rest}

  defp cond_parse(text), do: {:info, :editor, text}

  # ── Protocol encoding helpers ──

  @doc "Level byte for protocol encoding."
  @spec level_byte(level()) :: non_neg_integer()
  def level_byte(:debug), do: 0
  def level_byte(:info), do: 1
  def level_byte(:warning), do: 2
  def level_byte(:error), do: 3

  @doc "Subsystem byte for protocol encoding."
  @spec subsystem_byte(subsystem()) :: non_neg_integer()
  def subsystem_byte(:editor), do: 0
  def subsystem_byte(:lsp), do: 1
  def subsystem_byte(:parser), do: 2
  def subsystem_byte(:git), do: 3
  def subsystem_byte(:render), do: 4
  def subsystem_byte(:agent), do: 5
  def subsystem_byte(:zig), do: 6
  def subsystem_byte(:gui), do: 7

  @spec next_stream_instance() :: stream_instance()
  defp next_stream_instance do
    normalize_stream_instance(System.unique_integer([:monotonic, :positive]))
  end

  @spec normalize_stream_instance(pos_integer()) :: stream_instance()
  defp normalize_stream_instance(instance) do
    rem(instance - 1, 0xFFFF_FFFF) + 1
  end
end
