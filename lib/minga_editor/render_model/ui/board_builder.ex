defmodule MingaEditor.RenderModel.UI.BoardBuilder do
  @moduledoc false

  alias Minga.Log
  alias Minga.RenderModel.UI.Board

  @spec build(term()) :: Board.t()
  def build({:board, %Board{} = board}) do
    board
  end

  def build(nil) do
    Board.hidden()
  end

  def build(other) do
    Log.warning(
      :render,
      "Unsupported GUI shell payload #{inspect(other)}; dismissing Board surface"
    )

    Board.hidden()
  end
end
