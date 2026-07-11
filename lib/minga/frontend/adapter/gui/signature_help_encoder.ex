defmodule Minga.Frontend.Adapter.GUI.SignatureHelpEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.SignatureHelp
  alias Minga.RenderModel.UI.SignatureHelp.Parameter
  alias Minga.RenderModel.UI.SignatureHelp.Signature

  @op_gui_signature_help Opcodes.gui_signature_help()

  @spec encode(SignatureHelp.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%SignatureHelp{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_signature_help_fp do
      {encode_command(model), %{caches | last_signature_help_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(SignatureHelp.t()) :: binary()
  def encode_command(%SignatureHelp{visible?: false}), do: <<@op_gui_signature_help, 0::8>>

  def encode_command(%SignatureHelp{} = model) do
    writer =
      :gui_signature_help
      |> Writer.new()
      |> Writer.append(<<@op_gui_signature_help, 1::8>>)
      |> Writer.uint16(:anchor_row, model.anchor_row)
      |> Writer.uint16(:anchor_col, model.anchor_col)
      |> Writer.uint8(:active_signature, model.active_signature)
      |> Writer.uint8(:active_parameter, model.active_parameter)
      |> Writer.uint8(:signature_count, Enum.count(model.signatures))

    model.signatures
    |> Enum.reduce(writer, &encode_signature/2)
    |> Writer.finish()
  end

  @spec fingerprint(SignatureHelp.t()) :: term()
  defp fingerprint(%SignatureHelp{visible?: false}), do: :hidden

  defp fingerprint(%SignatureHelp{} = model) do
    {model.visible?, model.anchor_row, model.anchor_col, model.active_signature,
     model.active_parameter, model.signatures}
  end

  @spec encode_signature(Signature.t(), Writer.t()) :: Writer.t()
  defp encode_signature(%Signature{} = signature, %Writer{} = writer) do
    writer =
      writer
      |> Writer.string16(:signature_label, signature.label)
      |> Writer.string16(:signature_documentation, signature.documentation)
      |> Writer.uint8(:parameter_count, Enum.count(signature.parameters))

    Enum.reduce(signature.parameters, writer, &encode_parameter/2)
  end

  @spec encode_parameter(Parameter.t(), Writer.t()) :: Writer.t()
  defp encode_parameter(%Parameter{} = parameter, %Writer{} = writer) do
    writer
    |> Writer.string16(:parameter_label, parameter.label)
    |> Writer.string16(:parameter_documentation, parameter.documentation)
  end
end
