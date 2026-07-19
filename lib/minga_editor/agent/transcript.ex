defmodule MingaEditor.Agent.Transcript do
  @moduledoc """
  Pure semantic transcript projection for agent chat.

  The visible transcript is carried in `Minga.RenderModel.UI.AgentChat.resident_messages` and transported by `gui_agent_transcript` (0x86); `gui_agent_chat` (0x78) carries only chrome state. This module computes the transcript metadata that commands still need: displayed message windows, stable message ids, line-to-message lookup, code-block line classification, and provenance anchors.
  """

  @typedoc "Line offset: {message_index, start_line, line_count}"
  @type line_offset :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @typedoc "Line type for transcript-line-to-message mapping."
  @type line_type :: :text | :code | :tool | :thinking | :usage | :system | :empty

  @type empty_state :: :credentials_missing | :no_model | nil

  @type display_result :: %{
          line_index: [{non_neg_integer(), line_type()}],
          display_messages: [term()],
          display_message_pairs: [{pos_integer(), term()}],
          markdown: String.t(),
          line_offsets: [line_offset()]
        }

  @pinned_separator_id 4_000_000_001
  @hidden_separator_id 4_000_000_002
  @empty_state_index 4_000_000_010

  @doc "Builds displayed semantic transcript metadata from raw session messages."
  @spec display([term()], keyword()) :: display_result()
  def display(messages, opts \\ []) do
    display_start = Keyword.get(opts, :display_start_index, 0)
    pinned_ids = Keyword.get(opts, :pinned_ids, MapSet.new())
    message_id_pairs = Keyword.get(opts, :message_ids, [])
    empty_state = Keyword.get(opts, :empty_state)

    hidden_count = min(display_start, Enum.count(messages))

    visible_entries =
      messages
      |> Enum.with_index()
      |> Enum.drop(hidden_count)
      |> Enum.map(fn {msg, idx} -> {idx, msg} end)

    pinned_entries = extract_pinned_message_entries(message_id_pairs, pinned_ids, hidden_count)

    {visible_entries, pinned_entries, hidden_count, message_id_pairs} =
      maybe_use_empty_state(
        messages,
        empty_state,
        visible_entries,
        pinned_entries,
        hidden_count,
        message_id_pairs
      )

    {markdown, line_offsets, display_messages, display_message_pairs} =
      build_display_text(visible_entries, pinned_entries, hidden_count, message_id_pairs)

    text_lines = String.split(markdown, "\n")

    %{
      line_index: build_line_index(display_messages, text_lines, line_offsets),
      display_messages: display_messages,
      display_message_pairs: display_message_pairs,
      markdown: markdown,
      line_offsets: line_offsets
    }
  end

  @doc "Builds a per-line index mapping transcript lines to message indices and line types."
  @spec line_message_index([term()]) :: [{non_neg_integer(), line_type()}]
  def line_message_index([]), do: []

  def line_message_index(messages) do
    {text, line_offsets} = messages_to_markdown_with_offsets(messages)
    text_lines = String.split(text, "\n")
    build_line_index(messages, text_lines, line_offsets)
  end

  @doc "Returns the semantic transcript line where a message starts."
  @spec message_start_line([term()], non_neg_integer()) :: non_neg_integer() | nil
  def message_start_line(messages, msg_idx) do
    {_text, line_offsets} = messages_to_markdown_with_offsets(messages)

    case Enum.find(line_offsets, fn {idx, _start, _count} -> idx == msg_idx end) do
      {_idx, start, _count} -> start
      nil -> nil
    end
  end

  @doc "Converts transcript messages to plain markdown text and line offsets."
  @spec messages_to_markdown_with_offsets([term()]) :: {String.t(), [line_offset()]}
  def messages_to_markdown_with_offsets(messages) do
    {parts, offsets, _line} =
      messages
      |> Enum.with_index()
      |> Enum.reduce({[], [], 0}, fn {msg, idx}, {parts, offsets, line} ->
        md = message_to_markdown(msg)
        line_count = md |> String.split("\n") |> Enum.count()
        separator_lines = if parts == [], do: 0, else: 1
        start = line + separator_lines

        {[md | parts], [{idx, start, line_count} | offsets], start + line_count}
      end)

    text = parts |> Enum.reverse() |> Enum.join("\n\n")
    {text, Enum.reverse(offsets)}
  end

  @doc "Resolves the stable message id that should anchor a provenance jump for a tool call."
  @spec turn_anchor_id([{pos_integer(), term()}], String.t()) :: pos_integer() | nil
  def turn_anchor_id(messages_with_ids, tool_call_id) do
    case Enum.find_index(messages_with_ids, &tool_call_match?(&1, tool_call_id)) do
      nil ->
        nil

      tc_index ->
        before = Enum.take(messages_with_ids, tc_index)

        anchor_id(before, :user) || anchor_id(before, :thinking) ||
          elem(Enum.at(messages_with_ids, tc_index), 0)
    end
  end

  @spec message_to_markdown(term()) :: String.t()
  defp message_to_markdown({:user, text, _attachments}), do: message_to_markdown({:user, text})
  defp message_to_markdown({:user, text}), do: text
  defp message_to_markdown({:assistant, text}), do: text
  defp message_to_markdown({:thinking, text, _collapsed}), do: text

  defp message_to_markdown({:usage, %MingaAgent.TurnUsage{input: i, output: o, cost: c}})
       when is_integer(c) do
    "↑#{i} ↓#{o} $#{Float.round(c * 1.0, 3)}"
  end

  defp message_to_markdown({:usage, %MingaAgent.TurnUsage{input: i, output: o, cost: c}})
       when is_float(c) do
    "↑#{i} ↓#{o} $#{Float.round(c, 3)}"
  end

  defp message_to_markdown({:tool_call, tc}) do
    if tc.result != "", do: String.slice(tc.result, 0, 500), else: ""
  end

  defp message_to_markdown({:system, text, _level}), do: text
  defp message_to_markdown(_other), do: ""

  @spec build_line_index([term()], [String.t()], [line_offset()]) ::
          [{non_neg_integer(), line_type()}]
  defp build_line_index(_messages, [], _line_offsets), do: []

  defp build_line_index(messages, text_lines, line_offsets) do
    total_lines = Enum.count(text_lines)

    line_to_msg =
      line_offsets
      |> Enum.flat_map(fn {msg_idx, start, count} ->
        for offset <- 0..(count - 1), do: {start + offset, {msg_idx, start, count}}
      end)
      |> Map.new()

    fence_map = build_fence_map(messages, text_lines, line_offsets)

    for line_num <- 0..(total_lines - 1) do
      case Map.get(line_to_msg, line_num) do
        {msg_idx, _start_line, _count} ->
          msg = Enum.at(messages, msg_idx)
          {msg_idx, classify_line(msg, line_num, fence_map)}

        nil ->
          {prev_message_idx(line_offsets, line_num), :empty}
      end
    end
  end

  @spec prev_message_idx([line_offset()], non_neg_integer()) :: non_neg_integer()
  defp prev_message_idx(line_offsets, line_num) do
    line_offsets
    |> Enum.filter(fn {_idx, start, count} -> start + count <= line_num end)
    |> Enum.max_by(fn {_idx, start, _count} -> start end, fn -> {0, 0, 0} end)
    |> elem(0)
  end

  @spec build_fence_map([term()], [String.t()], [line_offset()]) ::
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
  defp classify_line({:assistant, _text}, line_num, fence_map),
    do: Map.get(fence_map, line_num, :text)

  defp classify_line({:thinking, _, _}, _line_num, _fence_map), do: :thinking
  defp classify_line({:tool_call, _}, _line_num, _fence_map), do: :tool
  defp classify_line({:usage, _}, _line_num, _fence_map), do: :usage
  defp classify_line({:system, _, _}, _line_num, _fence_map), do: :system
  defp classify_line(_msg, _line_num, _fence_map), do: :text

  @spec extract_pinned_message_entries([{pos_integer(), term()}], MapSet.t(), non_neg_integer()) ::
          [{non_neg_integer(), term()}]
  defp extract_pinned_message_entries(_pairs, pinned_ids, _hidden_count)
       when map_size(pinned_ids) == 0,
       do: []

  defp extract_pinned_message_entries(pairs, pinned_ids, hidden_count) do
    pairs
    |> Enum.with_index()
    |> Enum.filter(fn {{id, _msg}, idx} ->
      MapSet.member?(pinned_ids, id) and idx < hidden_count
    end)
    |> Enum.map(fn {{_id, msg}, idx} -> {idx, msg} end)
  end

  @spec maybe_use_empty_state(
          [term()],
          empty_state(),
          [{non_neg_integer(), term()}],
          [{non_neg_integer(), term()}],
          non_neg_integer(),
          [{pos_integer(), term()}]
        ) ::
          {[{non_neg_integer(), term()}], [{non_neg_integer(), term()}], non_neg_integer(),
           [{pos_integer(), term()}]}
  defp maybe_use_empty_state(
         messages,
         empty_state,
         visible_entries,
         pinned_entries,
         hidden_count,
         message_id_pairs
       )
       when empty_state in [:credentials_missing, :no_model] do
    if first_run_transcript?(messages) do
      {[{@empty_state_index, empty_state_message(empty_state)}], [], 0, []}
    else
      {visible_entries, pinned_entries, hidden_count, message_id_pairs}
    end
  end

  defp maybe_use_empty_state(
         _messages,
         _empty_state,
         visible_entries,
         pinned_entries,
         hidden_count,
         message_id_pairs
       ) do
    {visible_entries, pinned_entries, hidden_count, message_id_pairs}
  end

  @doc false
  @spec first_run_transcript?([term()]) :: boolean()
  def first_run_transcript?(messages) do
    not Enum.any?(messages, &user_facing_turn_message?/1)
  end

  @spec user_facing_turn_message?(term()) :: boolean()
  defp user_facing_turn_message?({kind, _}) when kind in [:user, :assistant, :tool_call, :usage],
    do: true

  defp user_facing_turn_message?({kind, _, _}) when kind in [:user, :thinking], do: true
  defp user_facing_turn_message?(_message), do: false

  @spec empty_state_message(:credentials_missing | :no_model) :: {:system, String.t(), :info}
  defp empty_state_message(:credentials_missing) do
    {:system,
     """
     Connect a provider

     Add an API key with /auth <provider> <key>, or run /login to sign in with a ChatGPT subscription.

     Examples:
       /auth anthropic <key>
       /auth openai <key>
       /auth google <key>
     """, :info}
  end

  defp empty_state_message(:no_model) do
    {:system,
     """
     Pick a model

     Use the model picker button, /model, or SPC a m to choose a configured model before starting a chat.
     """, :info}
  end

  @spec build_display_text(
          [{non_neg_integer(), term()}],
          [{non_neg_integer(), term()}],
          non_neg_integer(),
          [{pos_integer(), term()}]
        ) :: {String.t(), [line_offset()], [term()], [{pos_integer(), term()}]}
  defp build_display_text(visible_entries, pinned_entries, hidden_count, message_id_pairs) do
    prefix_entries =
      if pinned_entries != [] do
        Enum.concat(pinned_entries, [
          {separator_index(pinned_entries, visible_entries), {:system, "── pinned ──", :info}}
        ])
      else
        []
      end

    separator_entries =
      if hidden_count > 0 do
        [
          {separator_index(visible_entries, pinned_entries),
           {:system, "── #{hidden_count} earlier messages hidden ──", :info}}
        ]
      else
        []
      end

    display_entries = prefix_entries ++ separator_entries ++ visible_entries
    display_messages = Enum.map(display_entries, fn {_idx, msg} -> msg end)
    display_message_pairs = display_message_pairs(display_entries, message_id_pairs)
    {text, offsets} = messages_to_markdown_with_offsets(display_messages)
    {text, offsets, display_messages, display_message_pairs}
  end

  @spec display_message_pairs([{non_neg_integer(), term()}], [{pos_integer(), term()}]) ::
          [{pos_integer(), term()}]
  defp display_message_pairs(display_entries, message_id_pairs) do
    id_by_index =
      message_id_pairs
      |> Enum.with_index()
      |> Map.new(fn {{id, _msg}, idx} -> {idx, id} end)

    Enum.map(display_entries, fn {idx, msg} ->
      {display_message_id(idx, msg, id_by_index), msg}
    end)
  end

  @spec display_message_id(non_neg_integer(), term(), %{non_neg_integer() => pos_integer()}) ::
          pos_integer()
  defp display_message_id(_idx, {:system, "── pinned ──", :info}, _id_by_index),
    do: @pinned_separator_id

  defp display_message_id(_idx, {:system, "── " <> _rest, :info}, _id_by_index),
    do: @hidden_separator_id

  defp display_message_id(@empty_state_index, _msg, _id_by_index), do: @empty_state_index

  defp display_message_id(idx, _msg, id_by_index), do: Map.get(id_by_index, idx, idx + 1)

  @spec separator_index([{non_neg_integer(), term()}], [{non_neg_integer(), term()}]) ::
          non_neg_integer()
  defp separator_index([{idx, _msg} | _rest], _fallback_entries), do: idx
  defp separator_index([], [{idx, _msg} | _rest]), do: idx
  defp separator_index([], []), do: 0

  @spec tool_call_match?({pos_integer(), term()}, String.t()) :: boolean()
  defp tool_call_match?({_id, {:tool_call, %{id: tcid}}}, tool_call_id), do: tcid == tool_call_id
  defp tool_call_match?(_pair, _tool_call_id), do: false

  @spec anchor_id([{pos_integer(), term()}], :user | :thinking) :: pos_integer() | nil
  defp anchor_id(pairs, kind) do
    pairs
    |> Enum.reverse()
    |> Enum.find_value(fn {id, msg} -> if message_kind(msg) == kind, do: id end)
  end

  @spec message_kind(term()) :: atom()
  defp message_kind({kind, _}), do: kind
  defp message_kind({kind, _, _}), do: kind
  defp message_kind(_), do: :unknown
end
