defmodule Minga.Frontend.Adapter.GUI.AgentChatEncoder do
  @moduledoc """
  Pure GUI adapter encoder for the agent chat surface (`gui_agent_chat`, 0x78).

  Encodes a `Minga.RenderModel.UI.AgentChat` semantic model into the sectioned
  wire format and gates on a `:erlang.phash2/1` fingerprint stored in
  `Minga.Frontend.Adapter.GUI.Caches`. Depends only on the model, the protocol
  opcodes, and the caches struct; it touches no processes and references no
  product module. The editor builder pre-resolves every agent struct into the
  core views (`AgentChat.ToolCallView`, `AgentChat.ApprovalView`,
  `AgentChat.Usage`) before they reach this encoder.
  """

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias Minga.RenderModel.UI.AgentChat.MarkdownBlock
  alias Minga.RenderModel.UI.AgentChat.PromptCompletion
  alias Minga.RenderModel.UI.AgentChat.ToolCallView
  alias Minga.RenderModel.UI.AgentChat.Usage

  @op_gui_agent_chat Opcodes.gui_agent_chat()

  @max_u16 65_535

  @chat_message_limit 100
  @max_chat_text_bytes 60_000
  @truncation_suffix "\n… [truncated]"
  @chat_payload_omission_notice "Some agent chat content was omitted because the GUI chat payload exceeded 65KB."

  # gui_agent_chat sections
  @section_chat_header 0x01
  @section_chat_model 0x02
  @section_chat_prompt 0x03
  @section_chat_pending 0x04
  @section_chat_help 0x05
  @section_chat_messages 0x06
  @section_chat_completion 0x07
  @section_chat_thinking 0x08

  @spec encode(AgentChat.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%AgentChat{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(model)

    if fp != caches.last_agent_chat_fp do
      {encode_binary(model), %{caches | last_agent_chat_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_binary(AgentChat.t()) :: binary()
  defp encode_binary(%AgentChat{visible?: false}) do
    <<@op_gui_agent_chat, 0::8>>
  end

  defp encode_binary(%AgentChat{visible?: true} = model) do
    status_byte = encode_agent_chat_status(model.status)
    model_bytes = utf8_prefix_bytes(model.model_name || "", @max_u16 - 2)
    prompt_bytes = utf8_prefix_bytes(model.prompt || "", @max_u16 - 9)

    prompt_line_count = model.prompt_line_count || 1
    prompt_cursor_line = model.prompt_cursor_line || 0
    prompt_cursor_col = model.prompt_cursor_col || 0
    prompt_vim_mode = encode_vim_mode(model.prompt_vim_mode)
    prompt_visible_rows = model.prompt_visible_rows || 1

    completion_bytes = encode_prompt_completion(model.prompt_completion)
    pending_bytes = <<0::8>>
    help_bytes = encode_help_overlay(model.help_visible?, model.help_groups)
    thinking_bytes = utf8_prefix_bytes(model.thinking_level || "", @max_u16 - 2)

    messages_payload = encode_chat_messages(model.messages)

    sections = [
      encode_section(@section_chat_header, <<1::8, status_byte::8>>),
      encode_section(@section_chat_model, <<byte_size(model_bytes)::16, model_bytes::binary>>),
      encode_section(
        @section_chat_prompt,
        <<byte_size(prompt_bytes)::16, prompt_bytes::binary, prompt_line_count::8,
          prompt_cursor_line::16, prompt_cursor_col::16, prompt_vim_mode::8,
          prompt_visible_rows::8>>
      ),
      encode_section(@section_chat_completion, completion_bytes),
      encode_section(@section_chat_pending, pending_bytes),
      encode_section(@section_chat_help, help_bytes),
      encode_section(
        @section_chat_thinking,
        <<byte_size(thinking_bytes)::16, thinking_bytes::binary>>
      ),
      encode_section(@section_chat_messages, messages_payload)
    ]

    IO.iodata_to_binary([<<@op_gui_agent_chat, length(sections)::8>> | sections])
  end

  @spec encode_section(non_neg_integer(), binary()) :: binary()
  defp encode_section(section_id, payload) do
    <<section_id::8, byte_size(payload)::16, payload::binary>>
  end

  # ── Prompt completion ──

  # Wire format: visible(u8) [type(u8) selected(u8) anchor_line(u16) anchor_col(u16)
  #   candidate_count(u8) [name_len(u16) name(utf8) desc_len(u16) desc(utf8)]*]
  # type: 0=mention, 1=slash
  @spec encode_prompt_completion(PromptCompletion.t() | nil) :: binary()
  defp encode_prompt_completion(nil), do: <<0::8>>

  defp encode_prompt_completion(%PromptCompletion{candidates: candidates} = comp)
       when is_list(candidates) and candidates != [] do
    type_byte = if comp.type == :slash, do: 1, else: 0
    anchor_line = comp.anchor_line || 0
    anchor_col = comp.anchor_col || 0
    candidate_count = min(length(candidates), 255)

    candidate_bins =
      candidates
      |> Enum.take(candidate_count)
      |> Enum.map(fn
        {name, desc} ->
          n = :erlang.iolist_to_binary([name])
          d = :erlang.iolist_to_binary([desc])
          <<byte_size(n)::16, n::binary, byte_size(d)::16, d::binary>>

        name when is_binary(name) ->
          n = :erlang.iolist_to_binary([name])
          <<byte_size(n)::16, n::binary, 0::16>>
      end)

    IO.iodata_to_binary([
      <<1::8, type_byte::8, min(comp.selected, 255)::8, anchor_line::16, anchor_col::16,
        candidate_count::8>>
      | candidate_bins
    ])
  end

  defp encode_prompt_completion(_), do: <<0::8>>

  # ── Help overlay ──

  # Wire format: visible(1) [workspace_count(1) [title_len(2) title(utf8)
  #   binding_count(1) [key_len(1) key(utf8) desc_len(2) desc(utf8)]...]*]
  @spec encode_help_overlay(boolean() | nil, [{String.t(), [{String.t(), String.t()}]}] | nil) ::
          binary()
  defp encode_help_overlay(true, groups) when is_list(groups) and groups != [] do
    group_binaries =
      Enum.map(groups, fn {title, bindings} ->
        title_b = :erlang.iolist_to_binary([title])

        binding_binaries =
          Enum.map(bindings, fn {key, desc} ->
            key_b = :erlang.iolist_to_binary([key])
            desc_b = :erlang.iolist_to_binary([desc])

            <<byte_size(key_b)::8, key_b::binary, byte_size(desc_b)::16, desc_b::binary>>
          end)

        IO.iodata_to_binary([
          <<byte_size(title_b)::16, title_b::binary, length(bindings)::8>>
          | binding_binaries
        ])
      end)

    IO.iodata_to_binary([<<1::8, length(groups)::8>> | group_binaries])
  end

  defp encode_help_overlay(_, _), do: <<0::8>>

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
      <<preview_kind_byte(kind)::8, length(line_binaries)::16>> | line_binaries
    ])
  end

  defp encode_preview_payload(kind, _lines), do: <<preview_kind_byte(kind)::8, 0::16>>

  # ── Chat messages ──

  @typedoc "A chat message that may carry pre-computed styled runs."
  @type gui_chat_message :: AgentChat.message_body()

  @spec encode_chat_messages([AgentChat.message()]) :: binary()
  defp encode_chat_messages(messages) do
    messages = messages |> recent_chat_messages() |> Enum.map(&bound_chat_message_text/1)
    payload = encode_chat_messages_payload(messages)

    if byte_size(payload) <= @max_u16 do
      payload
    else
      stripped_messages = Enum.map(messages, &strip_chat_message_links/1)
      stripped_payload = encode_chat_messages_payload(stripped_messages)

      if byte_size(stripped_payload) <= @max_u16 do
        stripped_payload
      else
        stripped_messages
        |> fit_chat_messages_to_payload_limit()
        |> encode_chat_messages_payload()
      end
    end
  end

  @spec recent_chat_messages([AgentChat.message()]) :: [AgentChat.message()]
  defp recent_chat_messages(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take(@chat_message_limit)
    |> Enum.reverse()
  end

  @spec bound_chat_message_text(AgentChat.message()) :: AgentChat.message()
  defp bound_chat_message_text({id, msg}) when is_integer(id),
    do: {id, bound_chat_message_text(msg)}

  defp bound_chat_message_text({:user, text}),
    do: {:user, utf8_prefix_bytes(text, @max_chat_text_bytes)}

  defp bound_chat_message_text({:user, text, attachments}),
    do: {:user, utf8_prefix_bytes(text, @max_chat_text_bytes), attachments}

  defp bound_chat_message_text({:assistant, text}),
    do: {:assistant, utf8_prefix_bytes(text, @max_chat_text_bytes)}

  defp bound_chat_message_text({:thinking, text, collapsed}),
    do: {:thinking, utf8_prefix_bytes(text, @max_chat_text_bytes), collapsed}

  defp bound_chat_message_text({:system, text, level}),
    do: {:system, utf8_prefix_bytes(text, @max_chat_text_bytes), level}

  defp bound_chat_message_text(msg), do: msg

  @spec fit_chat_messages_to_payload_limit([AgentChat.message()]) :: [AgentChat.message()]
  defp fit_chat_messages_to_payload_limit(messages) do
    {selected, omitted?} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], false}, fn msg, {selected, omitted?} ->
        candidate = [msg | selected]

        if byte_size(encode_chat_messages_payload(candidate)) <= @max_u16 do
          {candidate, omitted?}
        else
          {selected, true}
        end
      end)

    if omitted?, do: add_chat_payload_omission_notice(selected), else: selected
  end

  @spec add_chat_payload_omission_notice([AgentChat.message()]) :: [AgentChat.message()]
  defp add_chat_payload_omission_notice([]) do
    [{:system, @chat_payload_omission_notice, :info}]
  end

  defp add_chat_payload_omission_notice(messages) do
    notice = {:system, @chat_payload_omission_notice, :info}

    if byte_size(encode_chat_messages_payload([notice | messages])) <= @max_u16 do
      [notice | messages]
    else
      [_dropped | rest] = messages
      add_chat_payload_omission_notice(rest)
    end
  end

  @spec encode_chat_messages_payload([AgentChat.message()]) :: binary()
  defp encode_chat_messages_payload(messages) do
    msg_binaries = Enum.map(messages, &encode_chat_message/1)

    framed_messages =
      Enum.map(msg_binaries, fn msg ->
        <<byte_size(msg)::32, msg::binary>>
      end)

    IO.iodata_to_binary([<<0xFF::8, 1::8, length(msg_binaries)::16>> | framed_messages])
  end

  @spec strip_chat_message_links(AgentChat.message()) :: AgentChat.message()
  defp strip_chat_message_links({id, msg}) when is_integer(id),
    do: {id, strip_chat_message_links(msg)}

  defp strip_chat_message_links({:styled_assistant, styled_lines}) do
    {:styled_assistant, strip_styled_lines_links(styled_lines)}
  end

  defp strip_chat_message_links({:styled_tool_call, tc, styled_lines}) do
    {:styled_tool_call, tc, strip_styled_lines_links(styled_lines)}
  end

  defp strip_chat_message_links({:assistant_markdown, blocks}) do
    {:assistant_markdown, strip_markdown_block_links(blocks)}
  end

  defp strip_chat_message_links(msg), do: msg

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

  # Unwrap {id, message} tuple: prefix with the stable uint32 ID, then encode the message.
  @spec encode_chat_message(AgentChat.message()) :: binary()
  defp encode_chat_message({id, msg}) when is_integer(id) do
    <<id::32, encode_chat_message_body(msg)::binary>>
  end

  # Bare messages (no ID wrapper) for backward compat. ID defaults to 0.
  defp encode_chat_message(msg) when is_tuple(msg) do
    <<0::32, encode_chat_message_body(msg)::binary>>
  end

  @spec encode_chat_message_body(gui_chat_message()) :: binary()
  defp encode_chat_message_body({:user, text}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x01::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message_body({:user, text, _attachments}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x01::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message_body({:assistant, text}) do
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x02::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  # Styled assistant message: opcode 0x07, line_count::16, then per line:
  # run_count::16, then per run: text_len::16, text, fg::24, bg::24, flags::8,
  # and when flags bit 0x08 is set: url_len::16, url.
  defp encode_chat_message_body({:styled_assistant, styled_lines}) do
    line_binaries =
      Enum.map(styled_lines, fn runs ->
        run_binaries = Enum.map(runs, &encode_styled_run/1)
        [<<length(runs)::16>> | run_binaries]
      end)

    IO.iodata_to_binary([<<0x07::8, length(styled_lines)::16>> | line_binaries])
  end

  # Assistant markdown message: opcode 0x0A, block_count::16, then semantic blocks.
  defp encode_chat_message_body({:assistant_markdown, blocks}) do
    bounded_blocks = bound_markdown_blocks(blocks)

    IO.iodata_to_binary([
      <<0x0A::8, length(bounded_blocks)::16>>,
      Enum.map(bounded_blocks, &encode_markdown_block/1)
    ])
  end

  defp encode_chat_message_body({:thinking, text, collapsed}) do
    collapsed_byte = if collapsed, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x03::8, collapsed_byte::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message_body({:tool_call, %ToolCallView{} = tc}) do
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
  defp encode_chat_message_body({:approval_tool_call, %ApprovalView{} = approval}) do
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
      preview_kind_byte(approval.preview_kind)::8, length(line_binaries)::16,
      preview_bytes::binary>>
  end

  # Styled tool call: same header fields as tool_call (0x04), but result is styled runs.
  # Sub-opcode 0x08. Layout:
  #   0x08, status::8, error::8, collapsed::8, duration::32, name_len::16, name,
  #   summary_len::16, summary, line_count::16, then per line: run_count::16,
  #   then per run: text_len::16, text, fg::24, bg::24, flags::8,
  #   and when flags bit 0x08 is set: url_len::16, url.
  #   auto_approved::8 and preview payload are appended after the styled line payload.
  defp encode_chat_message_body({:styled_tool_call, %ToolCallView{} = tc, styled_lines}) do
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
        [<<length(runs)::16>> | run_binaries]
      end)

    preview_bytes = encode_preview_payload(tc.preview_kind, tc.preview_lines)

    IO.iodata_to_binary([
      <<0x08::8, status_byte::8, error_byte::8, collapsed_byte::8, duration::32,
        byte_size(name_bytes)::16, name_bytes::binary, byte_size(summary_bytes)::16,
        summary_bytes::binary, length(styled_lines)::16>>,
      line_binaries,
      <<auto_approved_byte::8>>,
      preview_bytes
    ])
  end

  defp encode_chat_message_body({:system, text, level}) do
    level_byte = if level == :error, do: 1, else: 0
    text_bytes = :erlang.iolist_to_binary([text])
    <<0x05::8, level_byte::8, byte_size(text_bytes)::32, text_bytes::binary>>
  end

  defp encode_chat_message_body({:usage, %Usage{} = u}) do
    cost_int = round((u.cost || 0.0) * 1_000_000)
    <<0x06::8, u.input::32, u.output::32, u.cache_read::32, u.cache_write::32, cost_int::32>>
  end

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
        [<<length(runs)::16>> | run_binaries]
      end)

    IO.iodata_to_binary([<<length(styled_lines)::16>> | line_binaries])
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

  # ── UTF-8 truncation ──

  @spec utf8_prefix_bytes(String.t(), non_neg_integer()) :: binary()
  defp utf8_prefix_bytes(text, max_bytes) when byte_size(text) <= max_bytes do
    if String.valid?(text) do
      :erlang.iolist_to_binary([text])
    else
      valid_utf8_prefix(text, max_bytes)
    end
  end

  defp utf8_prefix_bytes(text, max_bytes) do
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

  # ── Enum byte helpers ──

  @spec encode_agent_chat_status(atom()) :: non_neg_integer()
  defp encode_agent_chat_status(:idle), do: 0
  defp encode_agent_chat_status(:thinking), do: 1
  defp encode_agent_chat_status(:tool_executing), do: 2
  defp encode_agent_chat_status(:error), do: 3
  defp encode_agent_chat_status(_), do: 0

  @spec encode_vim_mode(atom() | nil) :: non_neg_integer()
  defp encode_vim_mode(:normal), do: 0
  defp encode_vim_mode(:insert), do: 1
  defp encode_vim_mode(:visual), do: 2
  defp encode_vim_mode(:visual_line), do: 2
  defp encode_vim_mode(:command), do: 3
  defp encode_vim_mode(:operator_pending), do: 4
  defp encode_vim_mode(:search), do: 5
  defp encode_vim_mode(:search_prompt), do: 5
  defp encode_vim_mode(:replace), do: 6
  defp encode_vim_mode(_), do: 0
end
