defmodule Minga.Frontend.Adapter.GUI.AgentChatEncoder do
  @moduledoc """
  Pure GUI adapter encoder for the agent chat surface (`gui_agent_chat`, 0x78).

  Encodes the `gui_agent_chat` (0x78) chrome fields of a
  `Minga.RenderModel.UI.AgentChat` semantic model into the sectioned wire format
  and gates on a `:erlang.phash2/1` chrome fingerprint stored in
  `Minga.Frontend.Adapter.GUI.Caches`. Depends only on the model, the protocol
  opcodes, and the caches struct; it touches no processes and references no
  product module.

  This encoder owns only the small chrome transport for the agent chat surface.
  Resident transcript entries ride the dedicated `gui_agent_transcript` (0x86)
  stream via `Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder`, which uses
  `Minga.Frontend.Adapter.GUI.AgentChatMessageCodec` for the per-message bodies
  containing `AgentChat.ToolCallView`, `AgentChat.ApprovalView`, and
  `AgentChat.Usage`.
  """

  alias Minga.Design.Tokens
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.VimMode
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.PromptCompletion
  alias Minga.RenderModel.UI.AgentChat.StartRemedy

  @op_gui_agent_chat Opcodes.gui_agent_chat()

  @command :gui_agent_chat

  # gui_agent_chat sections
  @section_chat_header 0x01
  @section_chat_model 0x02
  @section_chat_prompt 0x03
  @section_chat_pending 0x04
  @section_chat_completion 0x07
  @section_chat_thinking 0x08
  # input_focused: whether the composer captures keys. A frontend that owns the
  # local transcript scroll (#2654) gates j/k on this so a scroll key is not
  # mistaken for composer cursor motion. Unknown sections are skipped by every
  # sectioned decoder, so this is backward/forward compatible.
  @section_chat_input_focused 0x09
  @section_chat_draft_attachment_count 0x0A
  @section_chat_question 0x0B
  @section_chat_stop_target 0x0C
  @section_chat_queue_target 0x0E
  @section_chat_lifecycle 0x0F

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
  # so exclude the resident-only fields from its change-detection fingerprint.
  @spec chrome_fingerprint_model(AgentChat.t()) :: AgentChat.t()
  defp chrome_fingerprint_model(%AgentChat{} = model) do
    %{model | resident_messages: [], resident_truncated?: false, transcript_epoch: 0}
  end

  @spec encode_binary(AgentChat.t()) :: binary()
  defp encode_binary(%AgentChat{visible?: false}) do
    <<@op_gui_agent_chat, 0::8>>
  end

  defp encode_binary(%AgentChat{visible?: true} = model) do
    sections = [
      encode_section(
        @section_chat_header,
        Writer.new(@command)
        |> Writer.uint8(:version, 1)
        |> Writer.uint8(:status, Tokens.agent_status_wire(model.status))
        |> Writer.finish()
      ),
      encode_section(
        @section_chat_model,
        Writer.new(@command)
        |> Writer.string16(:model_name, model.model_name || "")
        |> Writer.finish()
      ),
      encode_section(@section_chat_prompt, encode_prompt(model)),
      encode_section(@section_chat_completion, encode_prompt_completion(model.prompt_completion)),
      encode_section(@section_chat_pending, <<0::8>>),
      encode_section(
        @section_chat_thinking,
        Writer.new(@command)
        |> Writer.string16(:thinking_level, model.thinking_level || "")
        |> Writer.finish()
      ),
      encode_section(
        @section_chat_input_focused,
        Writer.new(@command)
        |> Writer.uint8(:input_focused, bool_byte(model.input_focused))
        |> Writer.finish()
      )
    ]

    sections =
      case {model.draft_attachment_count, model.draft_attachment_offer} do
        {0, nil} ->
          sections

        {count, offer} ->
          payload =
            Writer.new(@command)
            |> Writer.uint8(:draft_attachment_count, count)
            |> Writer.uint64(:draft_attachment_offer, offer || 0)
            |> Writer.finish()

          [encode_section(@section_chat_draft_attachment_count, payload) | sections]
      end

    sections =
      sections
      |> add_question_section(model.pending_question)
      |> add_stop_target_section(model.stop_target)
      |> add_queue_target_section(model.queue_target)
      |> add_lifecycle_section(model)

    sections =
      case model.prompt_presentation do
        nil ->
          sections

        generation ->
          payload =
            Writer.new(@command)
            |> Writer.uint64(:prompt_presentation, generation)
            |> Writer.finish()

          [encode_section(0x0D, payload) | sections]
      end

    Writer.new(@command)
    |> Writer.uint8(:opcode, @op_gui_agent_chat)
    |> Writer.uint8(:section_count, Enum.count(sections))
    |> Writer.append(sections)
    |> Writer.finish()
  end

  @spec add_lifecycle_section([binary()], AgentChat.t()) :: [binary()]
  defp add_lifecycle_section(sections, %AgentChat{lifecycle: :conversation}), do: sections

  # kind + reason, then the failed start's remedy: remedy kind (0 none, 1
  # retry, 2 set up provider) + action label + key hint. Other lifecycles send
  # no remedy and empty strings. The notice headline and the draft note follow;
  # an empty note means no note line.
  defp add_lifecycle_section(sections, %AgentChat{lifecycle: lifecycle} = model) do
    {kind, reason, remedy} =
      case lifecycle do
        :starting -> {1, "", nil}
        {:failed, reason, remedy} -> {2, String.byte_slice(reason, 0, 4096), remedy}
        :unavailable -> {3, "", nil}
      end

    {remedy_kind, label, key_hint} = encode_start_remedy(remedy)

    payload =
      Writer.new(@command)
      |> Writer.uint8(:lifecycle_kind, kind)
      |> Writer.string16(:lifecycle_reason, reason)
      |> Writer.uint8(:lifecycle_remedy, remedy_kind)
      |> Writer.string16(:lifecycle_action_label, label)
      |> Writer.string16(:lifecycle_key_hint, key_hint)
      |> Writer.string16(:lifecycle_headline, model.lifecycle_headline)
      |> Writer.string16(:lifecycle_note, model.draft_note)
      |> Writer.finish()

    [encode_section(@section_chat_lifecycle, payload) | sections]
  end

  @spec encode_start_remedy(StartRemedy.t() | nil) :: {0..2, String.t(), String.t()}
  defp encode_start_remedy(nil), do: {0, "", ""}

  defp encode_start_remedy(%StartRemedy{kind: kind, label: label, key_hint: key_hint}),
    do: {start_remedy_byte(kind), label, key_hint}

  @spec start_remedy_byte(StartRemedy.kind()) :: 1..2
  defp start_remedy_byte(:retry), do: 1
  defp start_remedy_byte(:set_up_provider), do: 2

  @spec add_queue_target_section([binary()], {String.t(), String.t(), pos_integer()} | nil) ::
          [binary()]
  defp add_queue_target_section(sections, nil), do: sections

  defp add_queue_target_section(sections, {record, request, sequence}) do
    payload =
      Writer.new(@command)
      |> Writer.string16(:queue_record, record)
      |> Writer.string16(:queue_request, request)
      |> Writer.uint64(:queue_sequence, sequence)
      |> Writer.finish()

    [encode_section(@section_chat_queue_target, payload) | sections]
  end

  @spec add_question_section([binary()], {pos_integer(), String.t()} | nil) :: [binary()]
  defp add_question_section(sections, nil), do: sections

  defp add_question_section(sections, {offer, prompt}) do
    payload =
      Writer.new(@command)
      |> Writer.uint64(:question_offer, offer)
      |> Writer.string16(:question_prompt, prompt)
      |> Writer.finish()

    [encode_section(@section_chat_question, payload) | sections]
  end

  @spec add_stop_target_section([binary()], {String.t(), String.t()} | nil) :: [binary()]
  defp add_stop_target_section(sections, nil), do: sections

  defp add_stop_target_section(sections, {session_id, request_id}) do
    payload =
      Writer.new(@command)
      |> Writer.string16(:stop_session_id, session_id)
      |> Writer.string16(:stop_request_id, request_id)
      |> Writer.finish()

    [encode_section(@section_chat_stop_target, payload) | sections]
  end

  @spec encode_prompt(AgentChat.t()) :: binary()
  defp encode_prompt(%AgentChat{} = model) do
    Writer.new(@command)
    |> Writer.string16(:prompt, model.prompt || "")
    |> Writer.uint8(:prompt_line_count, model.prompt_line_count || 1)
    |> Writer.uint16(:prompt_cursor_line, model.prompt_cursor_line || 0)
    |> Writer.uint16(:prompt_cursor_col, model.prompt_cursor_col || 0)
    |> Writer.uint8(:prompt_vim_mode, VimMode.encode(model.prompt_vim_mode))
    |> Writer.uint8(:prompt_visible_rows, model.prompt_visible_rows || 1)
    |> Writer.finish()
  end

  @spec encode_section(non_neg_integer(), binary()) :: binary()
  defp encode_section(section_id, payload) do
    Writer.new(@command)
    |> Writer.section16(:section_payload, section_id, payload)
    |> Writer.finish()
  end

  # ── Prompt completion ──

  # Wire format: visible(u8) [type(u8) selected(u8) anchor_line(u16) anchor_col(u16)
  #   candidate_count(u8) [name_len(u16) name(utf8) desc_len(u16) desc(utf8)]*]
  # type: 0=mention, 1=slash
  @spec encode_prompt_completion(PromptCompletion.t() | nil) :: binary()
  defp encode_prompt_completion(nil), do: <<0::8>>

  defp encode_prompt_completion(%PromptCompletion{candidates: candidates} = comp)
       when is_list(candidates) and candidates != [] do
    candidate_bins = Enum.map(candidates, &encode_completion_candidate/1)

    Writer.new(@command)
    |> Writer.uint8(:completion_visible, 1)
    |> Writer.uint8(:completion_type, if(comp.type == :slash, do: 1, else: 0))
    |> Writer.uint8(:completion_selected, comp.selected)
    |> Writer.uint16(:completion_anchor_line, comp.anchor_line || 0)
    |> Writer.uint16(:completion_anchor_col, comp.anchor_col || 0)
    |> Writer.uint8(:completion_candidate_count, Enum.count(candidates))
    |> Writer.append(candidate_bins)
    |> Writer.finish()
  end

  defp encode_prompt_completion(_), do: <<0::8>>

  @spec encode_completion_candidate(PromptCompletion.candidate()) :: binary()
  defp encode_completion_candidate({name, description}) do
    Writer.new(@command)
    |> Writer.string16(:completion_candidate_name, name)
    |> Writer.string16(:completion_candidate_description, description)
    |> Writer.finish()
  end

  defp encode_completion_candidate(name) when is_binary(name) do
    Writer.new(@command)
    |> Writer.string16(:completion_candidate_name, name)
    |> Writer.string16(:completion_candidate_description, "")
    |> Writer.finish()
  end

  # ── Enum byte helpers ──

  @spec bool_byte(boolean() | nil) :: 0 | 1
  defp bool_byte(true), do: 1
  defp bool_byte(_), do: 0
end
