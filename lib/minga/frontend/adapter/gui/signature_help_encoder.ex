defmodule Minga.Frontend.Adapter.GUI.SignatureHelpEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
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
    signatures = Enum.take(model.signatures, 255)
    active_signature = clamp_index(model.active_signature, length(signatures))

    active_parameter =
      clamp_active_parameter(model.active_parameter, Enum.at(signatures, active_signature))

    sig_data = Enum.map(signatures, &encode_signature/1)

    IO.iodata_to_binary([
      <<@op_gui_signature_help, 1::8, model.anchor_row::16, model.anchor_col::16,
        active_signature::8, active_parameter::8, length(signatures)::8>>
      | sig_data
    ])
  end

  @spec fingerprint(SignatureHelp.t()) :: term()
  defp fingerprint(%SignatureHelp{visible?: false}), do: :hidden

  defp fingerprint(%SignatureHelp{} = model) do
    {model.visible?, model.anchor_row, model.anchor_col, model.active_signature,
     model.active_parameter, model.signatures}
  end

  @spec encode_signature(Signature.t()) :: iodata()
  defp encode_signature(%Signature{} = signature) do
    label_bytes = :erlang.iolist_to_binary([signature.label])
    doc_bytes = :erlang.iolist_to_binary([signature.documentation])
    parameters = Enum.take(signature.parameters, 255)
    param_data = Enum.map(parameters, &encode_parameter/1)

    [
      <<byte_size(label_bytes)::16, label_bytes::binary, byte_size(doc_bytes)::16,
        doc_bytes::binary, length(parameters)::8>>
      | param_data
    ]
  end

  @spec encode_parameter(Parameter.t()) :: binary()
  defp encode_parameter(%Parameter{} = parameter) do
    label_bytes = :erlang.iolist_to_binary([parameter.label])
    doc_bytes = :erlang.iolist_to_binary([parameter.documentation])

    <<byte_size(label_bytes)::16, label_bytes::binary, byte_size(doc_bytes)::16,
      doc_bytes::binary>>
  end

  @spec clamp_active_parameter(non_neg_integer(), Signature.t() | nil) :: non_neg_integer()
  defp clamp_active_parameter(_active_parameter, nil), do: 0

  defp clamp_active_parameter(active_parameter, %Signature{} = signature) do
    clamp_index(active_parameter, min(length(signature.parameters), 255))
  end

  @spec clamp_index(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp clamp_index(_index, 0), do: 0
  defp clamp_index(index, count), do: min(index, count - 1)
end
