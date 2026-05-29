defmodule MingaEditor.RenderModel.UI.SignatureHelpBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.SignatureHelp
  alias Minga.RenderModel.UI.SignatureHelp.Parameter
  alias Minga.RenderModel.UI.SignatureHelp.Signature
  alias MingaEditor.SignatureHelp, as: EditorSignatureHelp

  @spec build(map()) :: SignatureHelp.t()
  def build(%{shell_state: %{signature_help: sh}}), do: signature_help_model(sh)
  def build(_ctx), do: %SignatureHelp{}

  @spec signature_help_model(EditorSignatureHelp.t() | nil) :: SignatureHelp.t()
  defp signature_help_model(nil), do: %SignatureHelp{}
  defp signature_help_model(%EditorSignatureHelp{signatures: []}), do: %SignatureHelp{}

  defp signature_help_model(%EditorSignatureHelp{} = sh) do
    %SignatureHelp{
      visible?: true,
      anchor_row: sh.anchor_row,
      anchor_col: sh.anchor_col,
      active_signature: sh.active_signature,
      active_parameter: sh.active_parameter,
      signatures: Enum.map(sh.signatures, &signature_model/1)
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
end
