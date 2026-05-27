defmodule Minga.Frontend.Adapter.GUI.WorkspacesEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.Workspaces

  @spec encode(Workspaces.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Workspaces{encoded: nil}, %Caches{} = caches) do
    {nil, caches}
  end

  def encode(%Workspaces{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_workspaces_fp do
      {model.encoded, %{caches | last_workspaces_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
