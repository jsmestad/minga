defmodule Minga.Frontend.Adapter.GUI.SignatureHelpEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.SignatureHelp

  @spec encode(SignatureHelp.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%SignatureHelp{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_signature_help_fp do
      {model.encoded, %{caches | last_signature_help_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
