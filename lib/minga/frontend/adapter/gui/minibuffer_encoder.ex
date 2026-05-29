defmodule Minga.Frontend.Adapter.GUI.MinibufferEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.Minibuffer
  alias Minga.RenderModel.UI.Minibuffer.Candidate

  @op_gui_minibuffer Opcodes.gui_minibuffer()

  @spec encode(Minibuffer.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Minibuffer{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_minibuffer_fp do
      {encode_command(model), %{caches | last_minibuffer_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(Minibuffer.t()) :: binary()
  def encode_command(%Minibuffer{visible?: false}), do: <<@op_gui_minibuffer, 0::8>>

  def encode_command(%Minibuffer{} = model) do
    prompt_bytes = :erlang.iolist_to_binary([model.prompt])
    input_bytes = :erlang.iolist_to_binary([model.input])
    context_bytes = :erlang.iolist_to_binary([model.context])
    candidate_data = Enum.map(model.candidates, &encode_candidate/1)
    mode = encode_mode(model.mode)
    cursor_pos = encode_cursor_pos(model.cursor_pos)

    IO.iodata_to_binary([
      <<@op_gui_minibuffer, 1::8, mode::8, cursor_pos::16, byte_size(prompt_bytes)::8,
        prompt_bytes::binary, byte_size(input_bytes)::16, input_bytes::binary,
        byte_size(context_bytes)::16, context_bytes::binary, model.selected_index::16,
        length(model.candidates)::16, model.total_candidates::16>>
      | candidate_data
    ])
  end

  @spec fingerprint(Minibuffer.t()) :: term()
  defp fingerprint(%Minibuffer{visible?: false}), do: :hidden

  defp fingerprint(%Minibuffer{} = model) do
    {model.visible?, model.mode, model.cursor_pos, model.prompt, model.input, model.context,
     model.selected_index, length(model.candidates), model.total_candidates, model.candidates}
  end

  @spec encode_mode(Minibuffer.mode()) :: non_neg_integer()
  defp encode_mode(:command), do: 0
  defp encode_mode(:search_forward), do: 1
  defp encode_mode(:search_backward), do: 2
  defp encode_mode(:search_prompt), do: 3
  defp encode_mode(:eval), do: 4
  defp encode_mode(:substitute_confirm), do: 5
  defp encode_mode(:extension_confirm), do: 6
  defp encode_mode(:describe_key), do: 7
  defp encode_mode(:delete_confirm), do: 8
  defp encode_mode(:branch_delete_confirm), do: 9
  defp encode_mode(:unknown), do: 0

  @spec encode_cursor_pos(non_neg_integer() | nil) :: non_neg_integer()
  defp encode_cursor_pos(nil), do: 0xFFFF
  defp encode_cursor_pos(cursor_pos), do: cursor_pos

  @spec encode_candidate(Candidate.t()) :: iodata()
  defp encode_candidate(%Candidate{} = candidate) do
    label_bytes = :erlang.iolist_to_binary([candidate.label])
    desc_bytes = :erlang.iolist_to_binary([candidate.description])
    annotation_bytes = :erlang.iolist_to_binary([candidate.annotation])
    match_positions = candidate.match_positions
    pos_binary = Enum.map(match_positions, fn pos -> <<min(pos, 0xFFFF)::16>> end)

    [
      <<min(candidate.match_score, 255)::8, byte_size(label_bytes)::16, label_bytes::binary,
        byte_size(desc_bytes)::16, desc_bytes::binary, byte_size(annotation_bytes)::16,
        annotation_bytes::binary, length(match_positions)::8>>
      | pos_binary
    ]
  end
end
