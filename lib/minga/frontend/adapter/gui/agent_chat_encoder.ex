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

  This is the legacy transcript transport: the `@section_chat_messages` section
  carries a windowed, byte-capped tail of the conversation. The full resident
  transcript now rides the dedicated `gui_agent_transcript` (0x86) stream via
  `Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder` (#2654). Both share the
  per-message body codec in `Minga.Frontend.Adapter.GUI.AgentChatMessageCodec`
  so the two transports encode each message with byte-identical bytes. The
  `messages` field this encoder consumes stays windowed until the frontends
  switch to consuming 0x86 (#2654 slices 2-3); the resident transcript never
  passes through this section.
  """

  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.PromptCompletion

  @op_gui_agent_chat Opcodes.gui_agent_chat()

  @max_u16 65_535

  @chat_message_limit 100
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
  # input_focused: whether the composer captures keys. A frontend that owns the
  # local transcript scroll (#2654) gates j/k on this so a scroll key is not
  # mistaken for composer cursor motion. Unknown sections are skipped by every
  # sectioned decoder, so this is backward/forward compatible.
  @section_chat_input_focused 0x09

  @spec encode(AgentChat.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%AgentChat{} = model, %Caches{} = caches) do
    fp = :erlang.phash2(chrome_fingerprint_model(model))

    if fp != caches.last_agent_chat_fp do
      {encode_binary(model), %{caches | last_agent_chat_fp: fp}}
    else
      {nil, caches}
    end
  end

  # The 0x78 chrome frame is independent of the resident transcript stream (0x86),
  # so exclude the resident-only fields from its change-detection fingerprint. A
  # streaming append that lands beyond the windowed `messages` tail must not force
  # a redundant chrome re-send.
  @spec chrome_fingerprint_model(AgentChat.t()) :: AgentChat.t()
  defp chrome_fingerprint_model(%AgentChat{} = model) do
    %{model | resident_messages: [], transcript_epoch: 0}
  end

  @spec encode_binary(AgentChat.t()) :: binary()
  defp encode_binary(%AgentChat{visible?: false}) do
    <<@op_gui_agent_chat, 0::8>>
  end

  defp encode_binary(%AgentChat{visible?: true} = model) do
    status_byte = encode_agent_chat_status(model.status)
    model_bytes = AgentChatMessageCodec.utf8_prefix_bytes(model.model_name || "", @max_u16 - 2)
    prompt_bytes = AgentChatMessageCodec.utf8_prefix_bytes(model.prompt || "", @max_u16 - 9)

    prompt_line_count = model.prompt_line_count || 1
    prompt_cursor_line = model.prompt_cursor_line || 0
    prompt_cursor_col = model.prompt_cursor_col || 0
    prompt_vim_mode = encode_vim_mode(model.prompt_vim_mode)
    prompt_visible_rows = model.prompt_visible_rows || 1

    completion_bytes = encode_prompt_completion(model.prompt_completion)
    pending_bytes = <<0::8>>
    help_bytes = encode_help_overlay(model.help_visible?, model.help_groups)

    thinking_bytes =
      AgentChatMessageCodec.utf8_prefix_bytes(model.thinking_level || "", @max_u16 - 2)

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
      encode_section(@section_chat_input_focused, <<bool_byte(model.input_focused)::8>>),
      encode_section(@section_chat_messages, messages_payload)
    ]

    IO.iodata_to_binary([<<@op_gui_agent_chat, Enum.count(sections)::8>> | sections])
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
    candidate_count = min(Enum.count(candidates), 255)

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
          <<byte_size(title_b)::16, title_b::binary, Enum.count(bindings)::8>>
          | binding_binaries
        ])
      end)

    IO.iodata_to_binary([<<1::8, Enum.count(groups)::8>> | group_binaries])
  end

  defp encode_help_overlay(_, _), do: <<0::8>>

  # ── Chat messages (windowed, byte-capped legacy section) ──

  @spec encode_chat_messages([AgentChat.message()]) :: binary()
  defp encode_chat_messages(messages) do
    messages =
      messages
      |> recent_chat_messages()
      |> Enum.map(&AgentChatMessageCodec.bound_message_text/1)

    payload = encode_chat_messages_payload(messages)

    if byte_size(payload) <= @max_u16 do
      payload
    else
      stripped_messages = Enum.map(messages, &AgentChatMessageCodec.strip_message_links/1)
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
    msg_binaries = Enum.map(messages, &AgentChatMessageCodec.encode_message/1)

    framed_messages =
      Enum.map(msg_binaries, fn msg ->
        <<byte_size(msg)::32, msg::binary>>
      end)

    IO.iodata_to_binary([<<0xFF::8, 1::8, Enum.count(msg_binaries)::16>> | framed_messages])
  end

  # ── Enum byte helpers ──

  @spec encode_agent_chat_status(atom()) :: non_neg_integer()
  defp encode_agent_chat_status(:idle), do: 0
  defp encode_agent_chat_status(:thinking), do: 1
  defp encode_agent_chat_status(:tool_executing), do: 2
  defp encode_agent_chat_status(:error), do: 3
  defp encode_agent_chat_status(_), do: 0

  @spec bool_byte(boolean() | nil) :: 0 | 1
  defp bool_byte(true), do: 1
  defp bool_byte(_), do: 0

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
