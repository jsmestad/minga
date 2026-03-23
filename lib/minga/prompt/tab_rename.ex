defmodule Minga.Prompt.TabRename do
  @moduledoc """
  Prompt handler for renaming the active tab.

  Opens a text input with the current tab label prefilled.
  On submit, updates the tab label.
  """

  @behaviour Minga.Prompt.Handler

  alias Minga.Editor.State.TabBar

  @impl true
  @spec label() :: String.t()
  def label, do: "Rename tab: "

  @impl true
  @spec on_submit(String.t(), map()) :: map()
  def on_submit(text, %{tab_bar: %TabBar{} = tb} = state) do
    trimmed = String.trim(text)

    if trimmed == "" do
      %{state | status_msg: "Tab name cannot be empty"}
    else
      tb = TabBar.update_label(tb, tb.active_id, trimmed)
      %{state | tab_bar: tb, status_msg: "Renamed: #{trimmed}"}
    end
  end

  def on_submit(_text, state), do: state

  @impl true
  @spec on_cancel(map()) :: map()
  def on_cancel(state), do: state
end
