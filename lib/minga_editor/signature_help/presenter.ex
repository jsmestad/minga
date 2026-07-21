defmodule MingaEditor.SignatureHelp.Presenter do
  @moduledoc "Builds signature-help geometry from its immutable value."

  alias MingaAgent.Markdown
  alias MingaEditor.FloatingWindow
  alias MingaEditor.SignatureHelp

  @doc "Returns the tooltip's conservative outer rect in screen cells."
  @spec box(SignatureHelp.t(), {pos_integer(), pos_integer()}) ::
          MingaEditor.Layout.rect() | nil
  def box(%SignatureHelp{} = signature_help, viewport) do
    case spec(signature_help, viewport) do
      nil -> nil
      window_spec -> FloatingWindow.box(window_spec)
    end
  end

  @spec spec(SignatureHelp.t(), {pos_integer(), pos_integer()}) ::
          FloatingWindow.Spec.t() | nil
  defp spec(%SignatureHelp{signatures: []}, _viewport), do: nil

  defp spec(%SignatureHelp{} = signature_help, viewport) do
    case Enum.at(signature_help.signatures, signature_help.active_signature) do
      nil -> nil
      signature -> build_spec(signature_help, signature, viewport)
    end
  end

  @spec build_spec(
          SignatureHelp.t(),
          SignatureHelp.signature(),
          {pos_integer(), pos_integer()}
        ) :: FloatingWindow.Spec.t()
  defp build_spec(signature_help, signature, viewport) do
    content_height = content_height(signature, signature_help.active_parameter)
    width = max(String.length(signature.label) + 4, 30) |> min(elem(viewport, 1) - 4)

    %FloatingWindow.Spec{
      width: {:cols, width + 2},
      height: {:rows, min(content_height, 8) + 2},
      position: {:anchor, signature_help.anchor_row, signature_help.anchor_col, :above},
      viewport: viewport
    }
  end

  @spec content_height(SignatureHelp.signature(), non_neg_integer()) :: pos_integer()
  defp content_height(signature, active_parameter) do
    case Enum.at(signature.parameters, active_parameter) do
      %{documentation: documentation} when documentation != "" ->
        2 + Enum.count(Markdown.parse(documentation))

      _other ->
        1
    end
  end
end
