defmodule Minga.Tool.UninstallPickerSource do
  @moduledoc """
  Picker source for uninstalling tools.

  Shows only installed tools. Selecting one triggers uninstall.
  """

  @behaviour Minga.UI.Picker.Source

  alias Minga.Tool.Manager, as: ToolManager
  alias Minga.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Uninstall Tool"

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(_context) do
    ToolManager.all_installed()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn inst ->
      %Item{
        id: inst.name,
        label: "#{inst.name} v#{inst.version}",
        description: "#{inst.method} • installed #{format_date(inst.installed_at)}"
      }
    end)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: name}, state) do
    case ToolManager.uninstall(name) do
      :ok -> %{state | status_msg: "Uninstalled #{name}"}
      {:error, reason} -> %{state | status_msg: "Failed to uninstall #{name}: #{reason}"}
    end
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec format_date(DateTime.t()) :: String.t()
  defp format_date(dt) do
    Calendar.strftime(dt, "%Y-%m-%d")
  end
end
