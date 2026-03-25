defmodule Minga.Agent.BufferSync do
  @moduledoc """
  Syncs agent conversation messages into a `*Agent*` BufferServer.

  Converts the session's message list into markdown text and writes
  it into the buffer. The buffer provides a vim-navigable view of
  the conversation, with tree-sitter markdown highlighting.
  """

  alias Minga.Agent.ChatDecorations
  alias Minga.Buffer.Server, as: BufferServer

  @doc """
  Starts the `*Agent*` buffer.

  Returns the buffer pid. The buffer is nofile (no save), read-only
  (no user edits), unlisted (hidden from buffer picker), and persistent
  (survives buffer kill).
  """
  @spec start_buffer() :: pid() | nil
  def start_buffer do
    case BufferServer.start_link(
           content: "",
           buffer_type: :nofile,
           buffer_name: "*Agent*",
           filetype: :markdown,
           read_only: true,
           unlisted: true,
           persistent: true
         ) do
      {:ok, pid} ->
        BufferServer.set_option(pid, :line_numbers, :none)
        # Word wrapping is desired but currently mutually exclusive with
        # DisplayMap (block decorations). Leave off until that interaction
        # is resolved. See render_pipeline/content.ex line ~135.
        # BufferServer.set_option(pid, :wrap, true)
        pid

      _ ->
        nil
    end
  end

  @doc """
  Syncs messages into the agent buffer as markdown text.

  Each message is rendered as a markdown section with a header.
  The buffer cursor is moved to the end (auto-scroll).

  Returns the line-to-message index computed from the synced content,
  so the caller can cache it in state for later lookups without
  recomputing.
  """
  @spec sync(pid(), [term()], keyword()) :: [{non_neg_integer(), line_type()}]
  def sync(pid, messages, opts \\ []) do
    msg_types =
      Enum.map(messages, fn
        {type, _} -> type
        {type, _, _} -> type
        other -> other
      end)

    Minga.Log.debug(:agent, "[buffer_sync] sync #{length(messages)} msgs: #{inspect(msg_types)}")

    {text, line_offsets} = messages_to_markdown_with_offsets(messages)
    text_lines = String.split(text, "\n")

    Minga.Log.debug(
      :agent,
      "[buffer_sync] offsets: #{inspect(line_offsets)}, text_lines: #{length(text_lines)}"
    )

    # Atomically replace content and rebuild decorations in one GenServer call.
    # This prevents a render frame from seeing new content with zero decorations.
    agent_theme = Keyword.get(opts, :agent_theme, default_agent_theme())
    last_line = max(length(text_lines) - 1, 0)

    try do
      BufferServer.replace_content_with_decorations(
        pid,
        text,
        fn decs ->
          ChatDecorations.build_decorations(decs, messages, line_offsets, agent_theme, opts)
        end,
        cursor: {last_line, 0}
      )
    rescue
      e ->
        Minga.Log.error(
          :agent,
          "[buffer_sync] atomic sync failed: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        # Fallback: at least replace content
        BufferServer.replace_content_force(pid, text)
    end

    # Return the line index, reusing the already-computed text and offsets
    build_line_index(messages, text_lines, line_offsets)
  end

  @doc false
  @spec messages_to_markdown_with_offsets([term()]) ::
          {String.t(), [ChatDecorations.line_offset()]}
  def messages_to_markdown_with_offsets(messages) do
    {parts, offsets, _line} =
      messages
      |> Enum.with_index()
      |> Enum.reduce({[], [], 0}, fn {msg, idx}, {parts, offsets, line} ->
        md = message_to_markdown(msg)
        line_count = md |> String.split("\n") |> length()
        # "\n\n" join adds 1 empty line between messages
        separator_lines = if parts == [], do: 0, else: 1
        start = line + separator_lines

        {[md | parts], [{idx, start, line_count} | offsets], start + line_count}
      end)

    text = parts |> Enum.reverse() |> Enum.join("\n\n")
    {text, Enum.reverse(offsets)}
  end

  # Buffer text is content only. Visual headers (▎ You, ▎ Agent, ┌─ ✓ bash)
  # are rendered by block decorations in ChatDecorations, not by markdown.
  @spec message_to_markdown(term()) :: String.t()
  defp message_to_markdown({:user, text, _attachments}), do: message_to_markdown({:user, text})
  defp message_to_markdown({:user, text}), do: text
  defp message_to_markdown({:assistant, text}), do: text
  defp message_to_markdown({:thinking, text, _collapsed}), do: text

  defp message_to_markdown({:usage, %Minga.Agent.TurnUsage{input: i, output: o, cost: c}})
       when is_integer(c) do
    "↑#{i} ↓#{o} $#{Float.round(c * 1.0, 3)}"
  end

  defp message_to_markdown({:usage, %Minga.Agent.TurnUsage{input: i, output: o, cost: c}})
       when is_float(c) do
    "↑#{i} ↓#{o} $#{Float.round(c, 3)}"
  end

  defp message_to_markdown({:tool_call, tc}) do
    if tc.result != "" do
      String.slice(tc.result, 0, 500)
    else
      ""
    end
  end

  defp message_to_markdown({:system, text, _level}), do: text

  defp message_to_markdown(_other), do: ""

  # ── Line-to-message index ──────────────────────────────────────────────────

  @typedoc "Line type for buffer-line-to-message mapping."
  @type line_type :: :text | :code | :tool | :thinking | :usage | :system | :empty

  @doc """
  Builds a per-buffer-line index mapping buffer lines to message indices and types.

  Returns a list where each element corresponds to a buffer line and contains
  `{message_index, line_type}`. The list is indexed by buffer line number.

  Prefer reading the cached index from `UIState.cached_line_index` when
  available (populated by `sync/3`). This function is the fallback for when
  the cache is empty (e.g., before the first sync).
  """
  @spec line_message_index([term()]) :: [{non_neg_integer(), line_type()}]
  def line_message_index([]), do: []

  def line_message_index(messages) do
    {text, line_offsets} = messages_to_markdown_with_offsets(messages)
    text_lines = String.split(text, "\n")
    build_line_index(messages, text_lines, line_offsets)
  end

  # Builds the line index from pre-computed text lines and offsets.
  # Used by both sync/3 (cached path) and line_message_index/1 (fallback).
  # All classification is O(n) in the total number of buffer lines.
  @spec build_line_index([term()], [String.t()], [ChatDecorations.line_offset()]) ::
          [{non_neg_integer(), line_type()}]
  defp build_line_index(_messages, [], _line_offsets), do: []

  defp build_line_index(messages, text_lines, line_offsets) do
    total_lines = length(text_lines)

    # Build a lookup: buffer_line -> {msg_idx, start_line, line_count}
    line_to_msg =
      line_offsets
      |> Enum.flat_map(fn {msg_idx, start, count} ->
        for offset <- 0..(count - 1), do: {start + offset, {msg_idx, start, count}}
      end)
      |> Map.new()

    # Pre-compute fence state for all assistant message lines in one O(n) pass.
    # Maps buffer_line_number -> :code | :text for lines in assistant messages.
    fence_map = build_fence_map(messages, text_lines, line_offsets)

    for line_num <- 0..(total_lines - 1) do
      case Map.get(line_to_msg, line_num) do
        {msg_idx, _start_line, _count} ->
          msg = Enum.at(messages, msg_idx)
          {msg_idx, classify_line(msg, line_num, fence_map)}

        nil ->
          # Separator line between messages ("\n\n" join).
          {prev_message_idx(line_offsets, line_num), :empty}
      end
    end
  end

  # Finds the message index of the message that ends just before the given line.
  @spec prev_message_idx([ChatDecorations.line_offset()], non_neg_integer()) ::
          non_neg_integer()
  defp prev_message_idx(line_offsets, line_num) do
    line_offsets
    |> Enum.filter(fn {_idx, start, count} -> start + count <= line_num end)
    |> Enum.max_by(fn {_idx, start, _count} -> start end, fn -> {0, 0, 0} end)
    |> elem(0)
  end

  # Pre-computes code/text classification for all assistant message lines
  # in a single O(n) pass. Returns a map: buffer_line -> :code | :text.
  # Non-assistant lines are not included (callers classify those by message type).
  @spec build_fence_map([term()], [String.t()], [ChatDecorations.line_offset()]) ::
          %{non_neg_integer() => :code | :text}
  defp build_fence_map(messages, text_lines, line_offsets) do
    line_offsets
    |> Enum.filter(fn {idx, _start, _count} ->
      match?({:assistant, _}, Enum.at(messages, idx))
    end)
    |> Enum.flat_map(fn {_idx, start, count} ->
      classify_assistant_fences(text_lines, start, count)
    end)
    |> Map.new()
  end

  # Walks one assistant message's lines in a single pass, tracking
  # fenced code block state. Returns [{line_num, :code | :text}].
  @spec classify_assistant_fences([String.t()], non_neg_integer(), non_neg_integer()) ::
          [{non_neg_integer(), :code | :text}]
  defp classify_assistant_fences(text_lines, start, count) do
    msg_lines = Enum.slice(text_lines, start, count)

    {entries, _in_code} =
      Enum.reduce(Enum.with_index(msg_lines), {[], false}, fn {line, offset}, {acc, in_code} ->
        is_fence = String.starts_with?(String.trim_leading(line), "```")
        new_in_code = if is_fence, do: not in_code, else: in_code
        type = if is_fence or new_in_code, do: :code, else: :text
        {[{start + offset, type} | acc], new_in_code}
      end)

    entries
  end

  @spec classify_line(term(), non_neg_integer(), %{non_neg_integer() => :code | :text}) ::
          line_type()
  defp classify_line({:assistant, _text}, line_num, fence_map) do
    Map.get(fence_map, line_num, :text)
  end

  defp classify_line({:thinking, _, _}, _line_num, _fence_map), do: :thinking
  defp classify_line({:tool_call, _}, _line_num, _fence_map), do: :tool
  defp classify_line({:usage, _}, _line_num, _fence_map), do: :usage
  defp classify_line({:system, _, _}, _line_num, _fence_map), do: :system
  defp classify_line(_msg, _line_num, _fence_map), do: :text

  @doc """
  Returns the buffer line number where the given message index starts.

  Returns nil if the message index is not found in the current layout.
  """
  @spec message_start_line([term()], non_neg_integer()) :: non_neg_integer() | nil
  def message_start_line(messages, msg_idx) do
    {_text, line_offsets} = messages_to_markdown_with_offsets(messages)

    case Enum.find(line_offsets, fn {idx, _start, _count} -> idx == msg_idx end) do
      {_idx, start, _count} -> start
      nil -> nil
    end
  end

  defp default_agent_theme do
    theme = Minga.UI.Theme.get!(Minga.UI.Theme.default())
    Minga.UI.Theme.agent_theme(theme)
  end
end
