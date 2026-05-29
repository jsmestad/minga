defmodule MingaEditor.RenderModel.UI.MinibufferBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.Minibuffer
  alias Minga.RenderModel.UI.Minibuffer.Candidate
  alias MingaEditor.MinibufferData

  @spec build(MinibufferData.t() | nil) :: Minibuffer.t()
  def build(%MinibufferData{} = data) do
    %Minibuffer{
      visible?: data.visible,
      mode: mode_model(data.mode),
      cursor_pos: cursor_pos_model(data.cursor_pos),
      prompt: data.prompt,
      input: data.input,
      context: data.context,
      selected_index: data.selected_index,
      candidates: Enum.map(data.candidates, &candidate_model/1),
      total_candidates: data.total_candidates
    }
  end

  def build(nil), do: %Minibuffer{}

  @spec mode_model(non_neg_integer()) :: Minibuffer.mode()
  defp mode_model(0), do: :command
  defp mode_model(1), do: :search_forward
  defp mode_model(2), do: :search_backward
  defp mode_model(3), do: :search_prompt
  defp mode_model(4), do: :eval
  defp mode_model(5), do: :substitute_confirm
  defp mode_model(6), do: :extension_confirm
  defp mode_model(7), do: :describe_key
  defp mode_model(8), do: :delete_confirm
  defp mode_model(9), do: :branch_delete_confirm
  defp mode_model(_mode), do: :unknown

  @spec cursor_pos_model(non_neg_integer()) :: non_neg_integer() | nil
  defp cursor_pos_model(0xFFFF), do: nil
  defp cursor_pos_model(cursor_pos), do: cursor_pos

  @spec candidate_model(MinibufferData.candidate()) :: Candidate.t()
  defp candidate_model(candidate) do
    %Candidate{
      label: Map.fetch!(candidate, :label),
      description: Map.get(candidate, :description, ""),
      match_score: Map.get(candidate, :match_score, 0),
      match_positions: Map.get(candidate, :match_positions, []),
      annotation: Map.get(candidate, :annotation, "")
    }
  end
end
