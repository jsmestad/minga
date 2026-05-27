defmodule Minga.Frontend.Adapter.GUI.AgentChatEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.AgentChat

  @spec encode(AgentChat.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%AgentChat{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_agent_chat_fp do
      {model.encoded, %{caches | last_agent_chat_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
