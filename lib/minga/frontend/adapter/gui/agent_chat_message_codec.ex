defmodule Minga.Frontend.Adapter.GUI.AgentChatMessageCodec do
  @moduledoc """
  Shared wire codec for a single agent-chat transcript message body.

  The resident `gui_agent_transcript` (0x86) stream uses this codec, so every
  data-derived bounded field is validated before it is written. Invalid values
  raise an encoding error rather than being truncated, dropped, or downgraded.
  """

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias Minga.RenderModel.UI.AgentChat.MarkdownBlock
  alias Minga.RenderModel.UI.AgentChat.ToolCallView
  alias Minga.RenderModel.UI.AgentChat.Usage

  @command :gui_agent_chat_message

  @doc "Stable uint32 id for a message, or 0 for a bare (unwrapped) body."
  @spec message_id(AgentChat.message()) :: non_neg_integer()
  def message_id({id, _body}) when is_integer(id), do: id
  def message_id(_body), do: 0

  @doc "Returns the 0x86 byte cost of one resident transcript entry."
  @spec resident_entry_size(AgentChat.message()) :: pos_integer()
  def resident_entry_size({id, body}) when is_integer(id),
    do: 8 + byte_size(encode_message_body(body))

  def resident_entry_size(body), do: 8 + byte_size(encode_message_body(body))

  @spec encode_message_body(AgentChat.message_body()) :: binary()
  def encode_message_body({:user, text}), do: encode_text_message(0x01, text)
  def encode_message_body({:user, text, _attachments}), do: encode_text_message(0x01, text)
  def encode_message_body({:assistant, text}), do: encode_text_message(0x02, text)

  def encode_message_body({:styled_assistant, styled_lines}) do
    Writer.new(@command)
    |> Writer.uint8(:message_kind, 0x07)
    |> Writer.uint16(:line_count, Enum.count(styled_lines))
    |> Writer.append(Enum.map(styled_lines, &encode_styled_line/1))
    |> Writer.finish()
  end

  def encode_message_body({:assistant_markdown, blocks}) do
    Writer.new(@command)
    |> Writer.uint8(:message_kind, 0x0A)
    |> Writer.uint16(:block_count, Enum.count(blocks))
    |> Writer.append(Enum.map(blocks, &encode_markdown_block/1))
    |> Writer.finish()
  end

  def encode_message_body({:thinking, text, collapsed}) do
    Writer.new(@command)
    |> Writer.uint8(:message_kind, 0x03)
    |> Writer.uint8(:collapsed, bool_byte(collapsed))
    |> Writer.string32(:text, text)
    |> Writer.finish()
  end

  def encode_message_body({:tool_call, %ToolCallView{} = tc}) do
    Writer.new(@command)
    |> Writer.uint8(:message_kind, 0x04)
    |> Writer.uint8(:status, tool_call_status_byte(tc.status))
    |> Writer.uint8(:is_error, bool_byte(tc.is_error))
    |> Writer.uint8(:collapsed, bool_byte(tc.collapsed))
    |> Writer.uint32(:duration_ms, tc.duration_ms || 0)
    |> Writer.string16(:tool_name, tc.name)
    |> Writer.string16(:summary, tc.summary || "")
    |> Writer.string32(:result, tc.result)
    |> Writer.uint8(:auto_approved_scope, auto_approved_scope_byte(tc.auto_approved_scope))
    |> Writer.append(encode_preview_payload(tc.preview_kind, tc.preview_lines))
    |> Writer.finish()
  end

  def encode_message_body({:approval_tool_call, %ApprovalView{} = approval}) do
    Writer.new(@command)
    |> Writer.uint8(:message_kind, 0x09)
    |> Writer.uint8(:status, 0)
    |> Writer.string16(:tool_name, approval.name)
    |> Writer.string16(:summary, approval.summary || "")
    |> Writer.string16(:tool_call_id, approval.tool_call_id)
    |> Writer.uint8(:preview_kind, preview_kind_byte(approval.preview_kind))
    |> Writer.uint16(:preview_line_count, Enum.count(approval.preview_lines))
    |> Writer.append(Enum.map(approval.preview_lines, &encode_preview_line/1))
    |> Writer.finish()
  end

  def encode_message_body({:styled_tool_call, %ToolCallView{} = tc, styled_lines}) do
    Writer.new(@command)
    |> Writer.uint8(:message_kind, 0x08)
    |> Writer.uint8(:status, tool_call_status_byte(tc.status))
    |> Writer.uint8(:is_error, bool_byte(tc.is_error))
    |> Writer.uint8(:collapsed, bool_byte(tc.collapsed))
    |> Writer.uint32(:duration_ms, tc.duration_ms || 0)
    |> Writer.string16(:tool_name, tc.name)
    |> Writer.string16(:summary, tc.summary || "")
    |> Writer.uint16(:line_count, Enum.count(styled_lines))
    |> Writer.append(Enum.map(styled_lines, &encode_styled_line/1))
    |> Writer.uint8(:auto_approved_scope, auto_approved_scope_byte(tc.auto_approved_scope))
    |> Writer.append(encode_preview_payload(tc.preview_kind, tc.preview_lines))
    |> Writer.finish()
  end

  def encode_message_body({:system, text, level}) do
    Writer.new(@command)
    |> Writer.uint8(:message_kind, 0x05)
    |> Writer.uint8(:level, if(level == :error, do: 1, else: 0))
    |> Writer.string32(:text, text)
    |> Writer.finish()
  end

  def encode_message_body({:usage, %Usage{} = usage}) do
    cost_int = round((usage.cost || 0.0) * 1_000_000)

    Writer.new(@command)
    |> Writer.uint8(:message_kind, 0x06)
    |> Writer.uint32(:input_tokens, usage.input)
    |> Writer.uint32(:output_tokens, usage.output)
    |> Writer.uint32(:cache_read_tokens, usage.cache_read)
    |> Writer.uint32(:cache_write_tokens, usage.cache_write)
    |> Writer.uint32(:cost_micros, cost_int)
    |> Writer.finish()
  end

  @spec encode_text_message(non_neg_integer(), String.t()) :: binary()
  defp encode_text_message(kind, text) do
    Writer.new(@command)
    |> Writer.uint8(:message_kind, kind)
    |> Writer.string32(:text, text)
    |> Writer.finish()
  end

  @spec encode_preview_payload(ToolCallView.preview_kind(), [String.t()]) :: binary()
  defp encode_preview_payload(kind, lines) when is_list(lines) do
    Writer.new(@command)
    |> Writer.uint8(:preview_kind, preview_kind_byte(kind))
    |> Writer.uint16(:preview_line_count, Enum.count(lines))
    |> Writer.append(Enum.map(lines, &encode_preview_line/1))
    |> Writer.finish()
  end

  defp encode_preview_payload(kind, _lines) do
    Writer.new(@command)
    |> Writer.uint8(:preview_kind, preview_kind_byte(kind))
    |> Writer.uint16(:preview_line_count, 0)
    |> Writer.finish()
  end

  @spec encode_preview_line(String.t()) :: binary()
  defp encode_preview_line(line) do
    Writer.new(@command)
    |> Writer.string16(:preview_line, line)
    |> Writer.finish()
  end

  @spec encode_markdown_block(MarkdownBlock.t()) :: binary()
  defp encode_markdown_block(%MarkdownBlock{kind: :paragraph} = block),
    do: encode_block_header(block, 0x01) <> encode_styled_lines(block.lines)

  defp encode_markdown_block(%MarkdownBlock{kind: :heading} = block) do
    encode_block_header(block, 0x02) <>
      (Writer.new(@command)
       |> Writer.uint8(:heading_level, block.level)
       |> Writer.append(encode_styled_lines(block.lines))
       |> Writer.finish())
  end

  defp encode_markdown_block(%MarkdownBlock{kind: :list_item} = block) do
    Writer.new(@command)
    |> Writer.append(encode_block_header(block, 0x03))
    |> Writer.uint8(:list_indent, block.indent)
    |> Writer.uint8(:list_ordered, bool_byte(block.ordered))
    |> Writer.uint32(:list_ordinal, block.ordinal)
    |> Writer.append(encode_styled_lines(block.lines))
    |> Writer.finish()
  end

  defp encode_markdown_block(%MarkdownBlock{kind: :blockquote} = block),
    do: encode_block_header(block, 0x04) <> encode_styled_lines(block.lines)

  defp encode_markdown_block(%MarkdownBlock{kind: :rule} = block),
    do: encode_block_header(block, 0x05)

  defp encode_markdown_block(%MarkdownBlock{kind: :spacer} = block) do
    Writer.new(@command)
    |> Writer.append(encode_block_header(block, 0x06))
    |> Writer.uint8(:spacer_height, block.height)
    |> Writer.finish()
  end

  defp encode_markdown_block(%MarkdownBlock{kind: :code_block} = block) do
    Writer.new(@command)
    |> Writer.append(encode_block_header(block, 0x07))
    |> Writer.string16(:code_language, block.language)
    |> Writer.string16(:code_label, block.label)
    |> Writer.string16(:code_target_path, block.target_path)
    |> Writer.uint8(:code_capability_flags, block.capability_flags)
    |> Writer.append(encode_styled_lines(block.lines))
    |> Writer.finish()
  end

  @spec encode_block_header(MarkdownBlock.t(), non_neg_integer()) :: binary()
  defp encode_block_header(%MarkdownBlock{} = block, kind) do
    Writer.new(@command)
    |> Writer.uint32(:block_id, block.id)
    |> Writer.uint8(:block_kind, kind)
    |> Writer.uint8(:block_flags, block.flags)
    |> Writer.finish()
  end

  @spec encode_styled_lines([AgentChat.styled_line()]) :: binary()
  defp encode_styled_lines(styled_lines) do
    Writer.new(@command)
    |> Writer.uint16(:line_count, Enum.count(styled_lines))
    |> Writer.append(Enum.map(styled_lines, &encode_styled_line/1))
    |> Writer.finish()
  end

  @spec encode_styled_line(AgentChat.styled_line()) :: binary()
  defp encode_styled_line(runs) do
    Writer.new(@command)
    |> Writer.uint16(:run_count, Enum.count(runs))
    |> Writer.append(Enum.map(runs, &encode_styled_run/1))
    |> Writer.finish()
  end

  @spec encode_styled_run(AgentChat.styled_run()) :: binary()
  defp encode_styled_run({text, fg, bg, flags, url}) do
    Writer.new(@command)
    |> Writer.check_uint8(:run_flags, flags)
    |> Writer.string16(:run_text, text)
    |> Writer.rgb24(:run_foreground, fg)
    |> Writer.rgb24(:run_background, bg)
    |> Writer.uint8(:run_flags, set_link_flag(flags))
    |> Writer.string16(:run_url, url)
    |> Writer.finish()
  end

  defp encode_styled_run({text, fg, bg, flags}) do
    Writer.new(@command)
    |> Writer.check_uint8(:run_flags, flags)
    |> Writer.string16(:run_text, text)
    |> Writer.rgb24(:run_foreground, fg)
    |> Writer.rgb24(:run_background, bg)
    |> Writer.uint8(:run_flags, clear_link_flag(flags))
    |> Writer.finish()
  end

  @spec set_link_flag(non_neg_integer()) :: non_neg_integer()
  defp set_link_flag(flags), do: flags ||| 0x08

  @spec clear_link_flag(non_neg_integer()) :: non_neg_integer()
  defp clear_link_flag(flags) when rem(flags, 16) >= 8, do: flags - 8
  defp clear_link_flag(flags), do: flags

  @spec preview_kind_byte(atom()) :: non_neg_integer()
  defp preview_kind_byte(:diff), do: 1
  defp preview_kind_byte(:command), do: 2
  defp preview_kind_byte(:target), do: 3
  defp preview_kind_byte(_), do: 0

  @spec tool_call_status_byte(ToolCallView.status()) :: 0 | 1 | 2
  defp tool_call_status_byte(:running), do: 0
  defp tool_call_status_byte(:complete), do: 1
  defp tool_call_status_byte(:error), do: 2

  @spec auto_approved_scope_byte(ToolCallView.auto_approved_scope()) :: 0 | 1 | 2
  defp auto_approved_scope_byte(:session), do: 1
  defp auto_approved_scope_byte(:turn), do: 2
  defp auto_approved_scope_byte(nil), do: 0

  @spec bool_byte(boolean()) :: 0 | 1
  defp bool_byte(true), do: 1
  defp bool_byte(false), do: 0
end
