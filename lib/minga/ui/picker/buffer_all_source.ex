defmodule Minga.UI.Picker.BufferAllSource do
  @moduledoc """
  Picker source for switching between all open buffers, including special
  buffers like `*Messages*`.

  This is the `SPC b B` variant. For the filtered default (`SPC b b`), see
  `Minga.UI.Picker.BufferSource`.
  """

  @behaviour Minga.UI.Picker.Source

  alias Minga.UI.Picker.Context
  alias Minga.UI.Picker.Item

  alias Minga.UI.Picker.BufferSource

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch buffer (all)"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

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
  @spec actions(Item.t()) :: [Minga.UI.Picker.Source.action_entry()]
  def actions(item), do: BufferSource.actions(item)

  @impl true
  @spec on_action(atom(), Item.t(), term()) :: term()
  def on_action(action, item, state), do: BufferSource.on_action(action, item, state)
end
