defmodule Minga.Frontend.Adapter.GUI.AgentChatMessageCodec do
  @moduledoc """
  Shared wire codec for a single agent-chat transcript message body.

  Extracted from `Minga.Frontend.Adapter.GUI.AgentChatEncoder` so the legacy
  `gui_agent_chat` (0x78) messages section and the resident `gui_agent_transcript`
  (0x86) stream encode each message with byte-identical bytes. This module owns
  only the per-message body encoding, the text/link bounding helpers, and the
  UTF-8 truncation primitive. Frame framing, section layout, and payload-fit
  policy stay with the two encoders that carry different transports.

  A `message` is a `Minga.RenderModel.UI.AgentChat.message()`: either a
  `{id, body}` tuple with a stable uint32 id, or a bare body tuple that encodes
  with id `0`.
  """

  import Bitwise

  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias Minga.RenderModel.UI.AgentChat.MarkdownBlock
  alias Minga.RenderModel.UI.AgentChat.ToolCallView
  alias Minga.RenderModel.UI.AgentChat.Usage

  @max_u16 65_535
  @max_chat_text_bytes 60_000
  @truncation_suffix "\n… [truncated]"

  @doc "Maximum per-message text byte budget shared by both transports."
  @spec max_message_text_bytes() :: pos_integer()
  def max_message_text_bytes, do: @max_chat_text_bytes

  @doc "Stable uint32 id for a message, or 0 for a bare (unwrapped) body."
  @spec message_id(AgentChat.message()) :: non_neg_integer()
  def message_id({id, _body}) when is_integer(id), do: id
  def message_id(_body), do: 0

  @doc "Encodes a full message as `<<id::32, body::binary>>`."
  @spec encode_message(AgentChat.message()) :: binary()
  def encode_message({id, body}) when is_integer(id),
    do: <<id::32, encode_message_body(body)::binary>>

  def encode_message(body) when is_tuple(body),
    do: <<0::32, encode_message_body(body)::binary>>

  @doc "Bounds a message's inline text to `max_message_text_bytes/0`."
  @spec bound_message_text(AgentChat.message()) :: AgentChat.message()
  def bound_message_text({id, msg}) when is_integer(id),
    do: {id, bound_message_text(msg)}

  def bound_message_text({:user, text}),
    do: {:user, utf8_prefix_bytes(text, @max_chat_text_bytes)}

  def bound_message_text({:user, text, attachments}),
    do: {:user, utf8_prefix_bytes(text, @max_chat_text_bytes), attachments}

  def bound_message_text({:assistant, text}),
    do: {:assistant, utf8_prefix_bytes(text, @max_chat_text_bytes)}

  def bound_message_text({:thinking, text, collapsed}),
    do: {:thinking, utf8_prefix_bytes(text, @max_chat_text_bytes), collapsed}

  def bound_message_text({:system, text, level}),
    do: {:system, utf8_prefix_bytes(text, @max_chat_text_bytes), level}

  def bound_message_text(msg), do: msg

  @doc "Strips embedded link URLs from a message (a size-reduction fallback)."
  @spec strip_message_links(AgentChat.message()) :: AgentChat.message()
  def strip_message_links({id, msg}) when is_integer(id),
    do: {id, strip_message_links(msg)}

  def strip_message_links({:styled_assistant, styled_lines}),
    do: {:styled_assistant, strip_styled_lines_links(styled_lines)}

  def strip_message_links({:styled_tool_call, tc, styled_lines}),
    do: {:styled_tool_call, tc, strip_styled_lines_links(styled_lines)}

  def strip_message_links({:assistant_markdown, blocks}),
    do: {:assistant_markdown, strip_markdown_block_links(blocks)}

  def strip_message_links(msg), do: msg

  # ── Message body ──

  @spec encode_message_body(AgentChat.message_body()) :: binary()
  def encode_message_body({:user, text}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x01::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  def encode_message_body({:user, text, _attachments}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x01::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  def encode_message_body({:assistant, text}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x02::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  # Styled assistant message: opcode 0x07, line_count::16, then per line:
  # run_count::16, then per run: text_len::16, text, fg::24, bg::24, flags::8,
  # and when flags bit 0x08 is set: url_len::16, url.
  def encode_message_body({:styled_assistant, styled_lines}) do
    line_binaries =
      Enum.map(styled_lines, fn runs ->
        run_binaries = Enum.map(runs, &encode_styled_run/1)
        [<<Enum.count(runs)::16>> | run_binaries]
      end)

    IO.iodata_to_binary([<<0x07::8, Enum.count(styled_lines)::16>> | line_binaries])
  end

  # Assistant markdown message: opcode 0x0A, block_count::16, then semantic blocks.
  def encode_message_body({:assistant_markdown, blocks}) do
    bounded_blocks = bound_markdown_blocks(blocks)

    IO.iodata_to_binary([
      <<0x0A::8, Enum.count(bounded_blocks)::16>>,
      Enum.map(bounded_blocks, &encode_markdown_block/1)
    ])
  end

  def encode_message_body({:thinking, text, collapsed}) do
    collapsed_byte = if collapsed, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x03::8, collapsed_byte::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  def encode_message_body({:tool_call, %ToolCallView{} = tc}) do
    name_bytes = :erlang.iolist_to_binary([tc.name])
    summary_bytes = utf8_prefix_bytes(tc.summary || "", @max_chat_text_bytes)
    result_bytes = :erlang.iolist_to_binary([tc.result])
    status_byte = tool_call_status_byte(tc.status)

    duration = tc.duration_ms || 0
    error_byte = if tc.is_error, do: 1, else: 0
    collapsed_byte = if tc.collapsed, do: 1, else: 0
    auto_approved_byte = auto_approved_scope_byte(tc.auto_approved_scope)

    preview_bytes = encode_preview_payload(tc.preview_kind, tc.preview_lines)

    <<0x04::8, status_byte::8, error_byte::8, collapsed_byte::8, duration::32,
      byte_size(name_bytes)::16, name_bytes::binary, byte_size(summary_bytes)::16,
      summary_bytes::binary, byte_size(result_bytes)::32, result_bytes::binary,
      auto_approved_byte::8, preview_bytes::binary>>
  end

  # Approval tool call: inline approval card attached to the tool message.
  # Sub-opcode 0x09. Layout:
  #   0x09, status::8, name_len::16, name, summary_len::16, summary,
  #   tool_call_id_len::16, tool_call_id, preview_kind::8,
  #   preview_line_count::16, [line_len::16, line]*
  def encode_message_body({:approval_tool_call, %ApprovalView{} = approval}) do
    name_bytes = preview_text_bytes(approval.name, 120)
    summary_bytes = approval_summary_bytes(approval.preview_kind, approval.summary)
    id_bytes = preview_text_bytes(approval.tool_call_id, 120)

    line_binaries =
      approval.preview_lines
      |> Enum.take(20)
      |> Enum.map(fn line ->
        bytes = preview_text_bytes(line, 1_000)
        <<byte_size(bytes)::16, bytes::binary>>
      end)

    preview_bytes = IO.iodata_to_binary(line_binaries)

    <<0x09::8, 0::8, byte_size(name_bytes)::16, name_bytes::binary, byte_size(summary_bytes)::16,
      summary_bytes::binary, byte_size(id_bytes)::16, id_bytes::binary,
      preview_kind_byte(approval.preview_kind)::8, Enum.count(line_binaries)::16,
      preview_bytes::binary>>
  end

  # Styled tool call: same header fields as tool_call (0x04), but result is styled runs.
  # Sub-opcode 0x08. Layout:
  #   0x08, status::8, error::8, collapsed::8, duration::32, name_len::16, name,
  #   summary_len::16, summary, line_count::16, then per line: run_count::16,
  #   then per run: text_len::16, text, fg::24, bg::24, flags::8,
  #   and when flags bit 0x08 is set: url_len::16, url.
  #   auto_approved::8 and preview payload are appended after the styled line payload.
  def encode_message_body({:styled_tool_call, %ToolCallView{} = tc, styled_lines}) do
    name_bytes = :erlang.iolist_to_binary([tc.name])
    summary_bytes = utf8_prefix_bytes(tc.summary || "", @max_chat_text_bytes)
    status_byte = tool_call_status_byte(tc.status)

    duration = tc.duration_ms || 0
    error_byte = if tc.is_error, do: 1, else: 0
    collapsed_byte = if tc.collapsed, do: 1, else: 0
    auto_approved_byte = auto_approved_scope_byte(tc.auto_approved_scope)

    line_binaries =
      Enum.map(styled_lines, fn runs ->
        run_binaries = Enum.map(runs, &encode_styled_run/1)
        [<<Enum.count(runs)::16>> | run_binaries]
      end)

    preview_bytes = encode_preview_payload(tc.preview_kind, tc.preview_lines)

    IO.iodata_to_binary([
      <<0x08::8, status_byte::8, error_byte::8, collapsed_byte::8, duration::32,
        byte_size(name_bytes)::16, name_bytes::binary, byte_size(summary_bytes)::16,
        summary_bytes::binary, Enum.count(styled_lines)::16>>,
      line_binaries,
      <<auto_approved_byte::8>>,
      preview_bytes
    ])
  end

  def encode_message_body({:system, text, level}) do
    level_byte = if level == :error, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x05::8, level_byte::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  def encode_message_body({:usage, %Usage{} = u}) do
    cost_int = round((u.cost || 0.0) * 1_000_000)
    <<0x06::8, u.input::32, u.output::32, u.cache_read::32, u.cache_write::32, cost_int::32>>
  end

  # ── Previews ──

  @spec preview_kind_byte(atom()) :: non_neg_integer()
  defp preview_kind_byte(:diff), do: 1
  defp preview_kind_byte(:command), do: 2
  defp preview_kind_byte(:target), do: 3
  defp preview_kind_byte(_), do: 0

  @spec preview_text_bytes(term(), pos_integer()) :: binary()
  defp preview_text_bytes(value, max_length) when is_binary(value) do
    value |> String.slice(0, max_length) |> :erlang.iolist_to_binary()
  end

  defp preview_text_bytes(value, max_length) do
    value
    |> inspect(printable_limit: max_length)
    |> String.slice(0, max_length)
    |> :erlang.iolist_to_binary()
  end

  @spec encode_preview_payload(ToolCallView.preview_kind(), [String.t()]) :: binary()
  defp encode_preview_payload(kind, lines) when is_list(lines) do
    line_binaries =
      lines
      |> Enum.take(20)
      |> Enum.map(fn line ->
        bytes = preview_text_bytes(line, 1_000)
        <<byte_size(bytes)::16, bytes::binary>>
      end)

    IO.iodata_to_binary([
      <<preview_kind_byte(kind)::8, Enum.count(line_binaries)::16>> | line_binaries
    ])
  end

  defp encode_preview_payload(kind, _lines), do: <<preview_kind_byte(kind)::8, 0::16>>

  @spec tool_call_status_byte(ToolCallView.status()) :: 0 | 1 | 2
  defp tool_call_status_byte(:running), do: 0
  defp tool_call_status_byte(:complete), do: 1
  defp tool_call_status_byte(:error), do: 2

  @spec approval_summary_bytes(ApprovalView.preview_kind(), String.t()) :: binary()
  defp approval_summary_bytes(:command, summary) do
    utf8_prefix_bytes(summary || "", @max_chat_text_bytes)
  end

  defp approval_summary_bytes(_kind, summary) do
    utf8_prefix_bytes(summary || "", 300)
  end

  @spec auto_approved_scope_byte(ToolCallView.auto_approved_scope()) :: 0 | 1 | 2
  defp auto_approved_scope_byte(:session), do: 1
  defp auto_approved_scope_byte(:turn), do: 2
  defp auto_approved_scope_byte(nil), do: 0

  # ── Markdown blocks ──

  @spec bound_markdown_blocks([MarkdownBlock.t()]) :: [MarkdownBlock.t()]
  defp bound_markdown_blocks(blocks) do
    Enum.map(blocks, fn %MarkdownBlock{} = block ->
      MarkdownBlock.map_lines(block, &bound_styled_line/1, 500)
    end)
  end

  @spec bound_styled_line(AgentChat.styled_line()) :: AgentChat.styled_line()
  defp bound_styled_line(runs), do: Enum.map(runs, &bound_styled_run/1)

  @spec bound_styled_run(AgentChat.styled_run()) :: AgentChat.styled_run()
  defp bound_styled_run({text, fg, bg, flags, url}),
    do: {utf8_prefix_bytes(text, 2_000), fg, bg, flags, url}

  defp bound_styled_run({text, fg, bg, flags}),
    do: {utf8_prefix_bytes(text, 2_000), fg, bg, flags}

  @spec encode_markdown_block(MarkdownBlock.t()) :: binary()
  defp encode_markdown_block(%MarkdownBlock{kind: :paragraph} = block),
    do: encode_block_header(block, 0x01) <> encode_styled_lines(block.lines)

  defp encode_markdown_block(%MarkdownBlock{kind: :heading} = block),
    do:
      encode_block_header(block, 0x02) <>
        <<min(block.level, 255)::8>> <> encode_styled_lines(block.lines)

  defp encode_markdown_block(%MarkdownBlock{kind: :list_item} = block) do
    ordered = if block.ordered, do: 1, else: 0

    encode_block_header(block, 0x03) <>
      <<min(block.indent, 255)::8, ordered::8, block.ordinal::32>> <>
      encode_styled_lines(block.lines)
  end

  defp encode_markdown_block(%MarkdownBlock{kind: :blockquote} = block),
    do: encode_block_header(block, 0x04) <> encode_styled_lines(block.lines)

  defp encode_markdown_block(%MarkdownBlock{kind: :rule} = block),
    do: encode_block_header(block, 0x05)

  defp encode_markdown_block(%MarkdownBlock{kind: :spacer} = block),
    do: encode_block_header(block, 0x06) <> <<min(block.height, 255)::8>>

  defp encode_markdown_block(%MarkdownBlock{kind: :code_block} = block) do
    language = utf8_prefix_bytes(block.language || "", @max_u16)
    label = utf8_prefix_bytes(block.label || "", @max_u16)
    target_path = utf8_prefix_bytes(block.target_path || "", @max_u16)

    IO.iodata_to_binary([
      encode_block_header(block, 0x07),
      <<byte_size(language)::16, language::binary, byte_size(label)::16, label::binary,
        byte_size(target_path)::16, target_path::binary, block.capability_flags::8>>,
      encode_styled_lines(block.lines)
    ])
  end

  @spec encode_block_header(MarkdownBlock.t(), non_neg_integer()) :: binary()
  defp encode_block_header(%MarkdownBlock{} = block, kind),
    do: <<block.id::32, kind::8, block.flags::8>>

  @spec encode_styled_lines([AgentChat.styled_line()]) :: binary()
  defp encode_styled_lines(styled_lines) do
    line_binaries =
      Enum.map(styled_lines, fn runs ->
        run_binaries = Enum.map(runs, &encode_styled_run/1)
        [<<Enum.count(runs)::16>> | run_binaries]
      end)

    IO.iodata_to_binary([<<Enum.count(styled_lines)::16>> | line_binaries])
  end

  @spec encode_styled_run(AgentChat.styled_run()) :: binary()
  defp encode_styled_run({text, fg, bg, flags, url}) do
    text_bytes = utf8_prefix_bytes(text, @max_u16)
    url_bytes = :erlang.iolist_to_binary([url])

    if byte_size(url_bytes) <= @max_u16 do
      link_flags = flags ||| 0x08

      <<byte_size(text_bytes)::16, text_bytes::binary, fg::24, bg::24, link_flags::8,
        byte_size(url_bytes)::16, url_bytes::binary>>
    else
      non_link_flags = flags &&& 0xF3
      encode_styled_run({text, fg, bg, non_link_flags})
    end
  end

  defp encode_styled_run({text, fg, bg, flags}) do
    text_bytes = utf8_prefix_bytes(text, @max_u16)
    safe_flags = flags &&& 0xF7
    <<byte_size(text_bytes)::16, text_bytes::binary, fg::24, bg::24, safe_flags::8>>
  end

  # ── Link stripping ──

  @spec strip_styled_lines_links([AgentChat.styled_line()]) :: [AgentChat.styled_line()]
  defp strip_styled_lines_links(styled_lines) do
    Enum.map(styled_lines, &strip_styled_line_links/1)
  end

  @spec strip_styled_line_links(AgentChat.styled_line()) :: AgentChat.styled_line()
  defp strip_styled_line_links(runs), do: Enum.map(runs, &strip_styled_run_link/1)

  @spec strip_styled_run_link(AgentChat.styled_run()) :: AgentChat.styled_run()
  defp strip_styled_run_link({text, fg, bg, flags, _url}), do: {text, fg, bg, flags &&& 0xF3}
  defp strip_styled_run_link(run), do: run

  @spec strip_markdown_block_links([MarkdownBlock.t()]) :: [MarkdownBlock.t()]
  defp strip_markdown_block_links(blocks) do
    Enum.map(blocks, fn %MarkdownBlock{} = block ->
      MarkdownBlock.map_lines(block, &strip_styled_line_links/1)
    end)
  end

  # ── UTF-8 truncation ──

  @doc "Truncates `text` to a valid UTF-8 prefix of at most `max_bytes` bytes."
  @spec utf8_prefix_bytes(String.t(), non_neg_integer()) :: binary()
  def utf8_prefix_bytes(text, max_bytes) when byte_size(text) <= max_bytes do
    if String.valid?(text) do
      :erlang.iolist_to_binary([text])
    else
      valid_utf8_prefix(text, max_bytes)
    end
  end

  def utf8_prefix_bytes(text, max_bytes) do
    suffix_bytes = :erlang.iolist_to_binary([@truncation_suffix])

    if max_bytes <= byte_size(suffix_bytes) do
      valid_utf8_prefix(text, max_bytes)
    else
      valid_utf8_prefix(text, max_bytes - byte_size(suffix_bytes)) <> suffix_bytes
    end
  end

  @spec valid_utf8_prefix(String.t(), non_neg_integer()) :: binary()
  defp valid_utf8_prefix(_text, 0), do: ""

  defp valid_utf8_prefix(text, max_bytes) do
    text
    |> binary_part(0, min(max_bytes, byte_size(text)))
    |> trim_invalid_utf8_suffix()
  end

  @spec trim_invalid_utf8_suffix(binary()) :: binary()
  defp trim_invalid_utf8_suffix(<<>>), do: ""

  defp trim_invalid_utf8_suffix(prefix) do
    if String.valid?(prefix) do
      prefix
    else
      prefix |> binary_part(0, byte_size(prefix) - 1) |> trim_invalid_utf8_suffix()
    end
  end
end
