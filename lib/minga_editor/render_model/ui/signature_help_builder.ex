defmodule MingaEditor.RenderModel.UI.SignatureHelpBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.SignatureHelp
  alias Minga.RenderModel.UI.SignatureHelp.Parameter
  alias Minga.RenderModel.UI.SignatureHelp.Signature
  alias MingaEditor.SignatureHelp, as: EditorSignatureHelp

  @max_encoded_items 255

  @spec build(map()) :: SignatureHelp.t()
  def build(%{shell_state: %{signature_help: sh}}), do: signature_help_model(sh)
  def build(_ctx), do: %SignatureHelp{}

  @spec signature_help_model(EditorSignatureHelp.t() | nil) :: SignatureHelp.t()
  defp signature_help_model(nil), do: %SignatureHelp{}
  defp signature_help_model(%EditorSignatureHelp{signatures: []}), do: %SignatureHelp{}

  defp signature_help_model(%EditorSignatureHelp{} = sh) do
    signatures = Enum.map(sh.signatures, &signature_model/1)

    active_signature =
      clamp_index(sh.active_signature, min(length(signatures), @max_encoded_items))

    active_parameter =
      clamp_active_parameter(sh.active_parameter, Enum.at(signatures, active_signature))

    %SignatureHelp{
      visible?: true,
      anchor_row: sh.anchor_row,
      anchor_col: sh.anchor_col,
      active_signature: active_signature,
      active_parameter: active_parameter,
      signatures: signatures
    }
  end

  @spec signature_model(EditorSignatureHelp.signature()) :: Signature.t()
  defp signature_model(signature) do
    %Signature{
      label: Map.get(signature, :label, ""),
      documentation: Map.get(signature, :documentation, ""),
      parameters: signature |> Map.get(:parameters, []) |> Enum.map(&parameter_model/1)
    }
  end

  @spec parameter_model(EditorSignatureHelp.parameter()) :: Parameter.t()
  defp parameter_model(parameter) do
    %Parameter{
      label: Map.get(parameter, :label, ""),
      documentation: Map.get(parameter, :documentation, "")
    }
  end

  @spec clamp_active_parameter(term(), Signature.t() | nil) :: non_neg_integer()
  defp clamp_active_parameter(_active_parameter, nil), do: 0

  defp clamp_active_parameter(active_parameter, %Signature{} = signature) do
    clamp_index(active_parameter, min(length(signature.parameters), @max_encoded_items))
  end

  @spec clamp_index(term(), non_neg_integer()) :: non_neg_integer()
  defp clamp_index(_index, 0), do: 0
  defp clamp_index(index, count) when is_integer(index) and index >= 0, do: min(index, count - 1)
  defp clamp_index(_index, _count), do: 0
end
