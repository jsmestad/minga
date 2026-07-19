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

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.AgentChat
  alias Minga.RenderModel.UI.AgentChat.PromptCompletion

  @op_gui_agent_chat Opcodes.gui_agent_chat()

  @command :gui_agent_chat

  # gui_agent_chat sections
  @section_chat_header 0x01
  @section_chat_model 0x02
  @section_chat_prompt 0x03
  @section_chat_pending 0x04
  @section_chat_help 0x05
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
        |> Writer.uint8(:status, encode_agent_chat_status(model.status))
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
        @section_chat_help,
        encode_help_overlay(model.help_visible?, model.help_groups)
      ),
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

    Writer.new(@command)
    |> Writer.uint8(:opcode, @op_gui_agent_chat)
    |> Writer.uint8(:section_count, Enum.count(sections))
    |> Writer.append(sections)
    |> Writer.finish()
  end

  @spec encode_prompt(AgentChat.t()) :: binary()
  defp encode_prompt(%AgentChat{} = model) do
    Writer.new(@command)
    |> Writer.string16(:prompt, model.prompt || "")
    |> Writer.uint8(:prompt_line_count, model.prompt_line_count || 1)
    |> Writer.uint16(:prompt_cursor_line, model.prompt_cursor_line || 0)
    |> Writer.uint16(:prompt_cursor_col, model.prompt_cursor_col || 0)
    |> Writer.uint8(:prompt_vim_mode, encode_vim_mode(model.prompt_vim_mode))
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

  # ── Help overlay ──

  # Wire format: visible(1) [workspace_count(1) [title_len(2) title(utf8)
  #   binding_count(1) [key_len(1) key(utf8) desc_len(2) desc(utf8)]...]*]
  @spec encode_help_overlay(boolean() | nil, [{String.t(), [{String.t(), String.t()}]}] | nil) ::
          binary()
  defp encode_help_overlay(true, groups) when is_list(groups) and groups != [] do
    Writer.new(@command)
    |> Writer.uint8(:help_visible, 1)
    |> Writer.uint8(:help_group_count, Enum.count(groups))
    |> Writer.append(Enum.map(groups, &encode_help_group/1))
    |> Writer.finish()
  end

  defp encode_help_overlay(_, _), do: <<0::8>>

  @spec encode_help_group({String.t(), [{String.t(), String.t()}]}) :: binary()
  defp encode_help_group({title, bindings}) do
    Writer.new(@command)
    |> Writer.string16(:help_group_title, title)
    |> Writer.uint8(:help_binding_count, Enum.count(bindings))
    |> Writer.append(Enum.map(bindings, &encode_help_binding/1))
    |> Writer.finish()
  end

  @spec encode_help_binding({String.t(), String.t()}) :: binary()
  defp encode_help_binding({key, description}) do
    Writer.new(@command)
    |> Writer.string8(:help_binding_key, key)
    |> Writer.string16(:help_binding_description, description)
    |> Writer.finish()
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
