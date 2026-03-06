defmodule Minga.Picker.BufferAllSource do
  @moduledoc """
  Picker source for switching between all open buffers, including special
  buffers like `*scratch*` and `*Messages*`.

  This is the `SPC b B` variant. For the filtered default (`SPC b b`), see
  `Minga.Picker.BufferSource`.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Picker.BufferSource

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch buffer (all)"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(state), do: BufferSource.build_candidates(state, include_special: true)

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select(item, state), do: BufferSource.on_select(item, state)

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: BufferSource.on_cancel(state)

  @impl true
  @spec actions(Minga.Picker.item()) :: [Minga.Picker.Source.action_entry()]
  def actions(item), do: BufferSource.actions(item)

  @impl true
  @spec on_action(atom(), Minga.Picker.item(), term()) :: term()
  def on_action(action, item, state), do: BufferSource.on_action(action, item, state)
end
