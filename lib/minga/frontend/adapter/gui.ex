defmodule Minga.Frontend.Adapter.GUI do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel

  @spec encode_ui(RenderModel.UI.t(), Caches.t()) :: {[binary()], Caches.t()}
  def encode_ui(%RenderModel.UI{} = _ui, %Caches{} = caches) do
    # Components will be added here as they migrate.
    # Each returns {binary() | nil, updated_caches}.
    # We collect non-nil commands.
    {[], caches}
  end
end
