defmodule MingaEditor.Test.PickerCallbackProbe do
  @moduledoc false

  @behaviour MingaEditor.UI.Picker.Source

  @impl true
  @spec title() :: term()
  def title, do: value(:title, "Probe")

  @impl true
  @spec candidates(MingaEditor.UI.Picker.Context.t()) :: term()
  def candidates(_context), do: value(:candidates, [])

  @impl true
  @spec on_select(MingaEditor.UI.Picker.item(), MingaEditor.State.t()) :: term()
  def on_select(_item, state), do: value(:on_select, state)

  @impl true
  @spec on_cancel(MingaEditor.State.t()) :: term()
  def on_cancel(state), do: value(:on_cancel, state)

  @impl true
  @spec preview?() :: term()
  def preview?, do: value(:preview?, false)

  @impl true
  @spec live_preview?() :: term()
  def live_preview?, do: value(:live_preview?, false)

  @impl true
  @spec gui_preview?() :: term()
  def gui_preview?, do: value(:gui_preview?, false)

  @impl true
  @spec preview(MingaEditor.UI.Picker.item(), MingaEditor.UI.Picker.Source.preview_context()) ::
          term()
  def preview(_item, _context), do: value(:preview, nil)

  @impl true
  @spec actions(MingaEditor.UI.Picker.item()) :: term()
  def actions(_item), do: value(:actions, [])

  @impl true
  @spec on_action(term(), MingaEditor.UI.Picker.item(), MingaEditor.State.t()) :: term()
  def on_action(_action, _item, state), do: value(:on_action, state)

  @impl true
  @spec on_bulk_select([MingaEditor.UI.Picker.item()], MingaEditor.State.t()) :: term()
  def on_bulk_select(_items, state), do: value(:on_bulk_select, state)

  @impl true
  @spec bulk_actions([MingaEditor.UI.Picker.item()]) :: term()
  def bulk_actions(_items), do: value(:bulk_actions, [])

  @impl true
  @spec on_bulk_action(term(), [MingaEditor.UI.Picker.item()], MingaEditor.State.t()) :: term()
  def on_bulk_action(_action, _items, state), do: value(:on_bulk_action, state)

  @impl true
  @spec layout() :: term()
  def layout, do: value(:layout, :bottom)

  @impl true
  @spec keep_open_on_select?() :: term()
  def keep_open_on_select?, do: value(:keep_open_on_select?, false)

  @impl true
  @spec async?() :: term()
  def async?, do: value(:async?, false)

  @impl true
  @spec async_fetch(MingaEditor.UI.Picker.Context.t()) :: term()
  def async_fetch(_context), do: value(:async_fetch, {:ok, [], %{}})

  @impl true
  @spec enrich([MingaEditor.UI.Picker.item()]) :: term()
  def enrich(items), do: value(:enrich, items)

  @spec raise_title() :: no_return()
  def raise_title, do: raise("picker callback failed")

  @spec value(atom(), term()) :: term()
  defp value(function, default), do: Process.get({__MODULE__, function}, default)
end
