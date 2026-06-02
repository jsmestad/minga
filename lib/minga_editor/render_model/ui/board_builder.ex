defmodule MingaEditor.RenderModel.UI.BoardBuilder do
  @moduledoc false

  alias Minga.Log
  alias Minga.RenderModel.UI.Board
  alias MingaEditor.Agent.SemanticUI.Registry, as: SemanticUIRegistry

  @spec build(term()) :: Board.t()
  def build(payload), do: build(payload, SemanticUIRegistry.default_table())

  @spec build(term(), SemanticUIRegistry.table()) :: Board.t()
  def build({:board, %Board{} = board}, agent_ui_registry) do
    Board.append_cards(board, SemanticUIRegistry.status_cards(agent_ui_registry))
  end

  def build(nil, _agent_ui_registry) do
    Board.hidden()
  end

  def build(other, _agent_ui_registry) do
    Log.warning(
      :render,
      "Unsupported GUI shell payload #{inspect(other)}; dismissing Board surface"
    )

    Board.hidden()
  end
end
