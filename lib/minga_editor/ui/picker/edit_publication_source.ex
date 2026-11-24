defmodule MingaEditor.UI.Picker.EditPublicationSource do
  @moduledoc """
  The one prompt behind `SPC a p`: publish Minga's staged edits to disk, or discard them.

  Publishing and discarding answer the same question about the same edits, so they share one key and one prompt instead of two leader keys.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.Commands.Workspace
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Publish edits"

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_context) do
    [
      %Item{id: :publish, label: "Publish", description: "Write Minga's staged edits to disk"},
      %Item{id: :discard, label: "Discard", description: "Throw away Minga's unpublished edits"}
    ]
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: :publish}, state), do: Workspace.agent_edits_publish(state)
  def on_select(%Item{id: :discard}, state), do: Workspace.agent_edits_discard(state)
  def on_select(_item, state), do: state
end
