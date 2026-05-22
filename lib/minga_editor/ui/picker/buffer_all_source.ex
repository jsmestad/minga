defmodule MingaEditor.UI.Picker.BufferAllSource do
  @moduledoc """
  Picker source for switching between all open buffers, including special
  buffers like `*Messages*`.

  This is the `SPC b B` variant. For the filtered default (`SPC b b`), see
  `MingaEditor.UI.Picker.BufferSource`.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  alias MingaEditor.UI.Picker.BufferSource

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch buffer (all)"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec gui_preview?() :: boolean()
  def gui_preview?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(ctx), do: BufferSource.build_candidates(ctx, include_special: true)

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(item, state), do: BufferSource.on_select(item, state)

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: BufferSource.on_cancel(state)

  @impl true
  @spec actions(Item.t()) :: [MingaEditor.UI.Picker.Source.action_entry()]
  def actions(item), do: BufferSource.actions(item)

  @impl true
  @spec on_action(term(), Item.t(), term()) :: term()
  def on_action(action, item, state), do: BufferSource.on_action(action, item, state)

  @impl true
  @spec on_bulk_select([Item.t()], term()) :: term()
  def on_bulk_select(items, state), do: BufferSource.on_bulk_select(items, state)

  @impl true
  @spec bulk_actions([Item.t()]) :: [MingaEditor.UI.Picker.Source.action_entry()]
  def bulk_actions(items), do: BufferSource.bulk_actions(items)

  @impl true
  @spec on_bulk_action(term(), [Item.t()], term()) :: term()
  def on_bulk_action(action, items, state), do: BufferSource.on_bulk_action(action, items, state)
end
