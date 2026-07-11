defmodule Minga.Frontend.Adapter.GUI.MinibufferEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
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
    writer =
      :gui_minibuffer
      |> Writer.new()
      |> Writer.append(<<@op_gui_minibuffer, 1::8>>)
      |> Writer.uint8(:mode, encode_mode(model.mode))
      |> Writer.uint16(:cursor_pos, encode_cursor_pos(model.cursor_pos))
      |> Writer.string8(:prompt, model.prompt)
      |> Writer.string16(:input, model.input)
      |> Writer.string16(:context, model.context)
      |> Writer.uint16(:selected_index, model.selected_index)
      |> Writer.uint16(:candidate_count, Enum.count(model.candidates))
      |> Writer.uint16(:total_candidates, model.total_candidates)

    model.candidates
    |> Enum.reduce(writer, &encode_candidate/2)
    |> Writer.finish()
  end

  @spec fingerprint(Minibuffer.t()) :: term()
  defp fingerprint(%Minibuffer{visible?: false}), do: :hidden

  defp fingerprint(%Minibuffer{} = model) do
    {model.visible?, model.mode, model.cursor_pos, model.prompt, model.input, model.context,
     model.selected_index, Enum.count(model.candidates), model.total_candidates, model.candidates}
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
  defp encode_mode(:text_prompt), do: 10
  defp encode_mode(:unknown), do: 0

  @spec encode_cursor_pos(non_neg_integer() | nil) :: non_neg_integer()
  defp encode_cursor_pos(nil), do: 0xFFFF
  defp encode_cursor_pos(cursor_pos), do: cursor_pos

  @spec encode_candidate(Candidate.t(), Writer.t()) :: Writer.t()
  defp encode_candidate(%Candidate{} = candidate, %Writer{} = writer) do
    writer =
      writer
      |> Writer.uint8(:candidate_match_score, candidate.match_score)
      |> Writer.string16(:candidate_label, candidate.label)
      |> Writer.string16(:candidate_description, candidate.description)
      |> Writer.string16(:candidate_annotation, candidate.annotation)
      |> Writer.uint8(:candidate_match_position_count, Enum.count(candidate.match_positions))

    Enum.reduce(candidate.match_positions, writer, fn position, acc ->
      Writer.uint16(acc, :candidate_match_position, position)
    end)
  end
end
