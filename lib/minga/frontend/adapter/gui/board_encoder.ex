defmodule Minga.Frontend.Adapter.GUI.BoardEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.Board

  @spec encode(Board.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%Board{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_board_fp do
      {model.encoded, %{caches | last_board_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
