defmodule MingaBoard.RenderModel.UI.BoardBuilder do
  @moduledoc false

  alias Minga.Log
  alias MingaBoard.RenderModel.UI.Board

  @spec build(term()) :: Board.t()
  def build({:board, %Board{} = board}), do: board

  def build(nil), do: Board.hidden()

  def build(other) do
    Log.warning(
      :render,
      "Unsupported Board extension GUI payload #{inspect(other)}; dismissing Board surface"
    )

    Board.hidden()
  end
end
