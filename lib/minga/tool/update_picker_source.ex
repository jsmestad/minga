defmodule Minga.Tool.UpdatePickerSource do
  @moduledoc """
  Picker source for updating installed tools.

  Shows installed tools. Selecting one triggers an update (uninstall + reinstall).
  """

  @behaviour Minga.UI.Picker.Source

  alias Minga.Tool.Manager, as: ToolManager
  alias Minga.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Update Tool"

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_context) do
    ToolManager.all_installed()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn inst ->
      %Item{
        id: inst.name,
        label: "#{inst.name} v#{inst.version}",
        description: "#{inst.method}"
      }
    end)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: name}, state) do
    case ToolManager.update(name) do
      :ok ->
        Minga.Editor.State.set_status(state, "Updating #{name}...")

      {:error, reason} ->
        Minga.Editor.State.set_status(state, "Failed to update #{name}: #{reason}")
    end
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state
end
