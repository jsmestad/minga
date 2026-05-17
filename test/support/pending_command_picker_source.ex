defmodule Minga.Test.PendingCommandPickerSource do
  @moduledoc "Test picker source that sets a pending command without being the command palette."

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Pending Command Test"

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_ctx), do: [%Item{id: :pick, label: "Pick"}]

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{}, state), do: Map.put(state, :pending_command, :save)

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state
end
