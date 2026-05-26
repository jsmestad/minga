defmodule MingaEditor.UI.Picker.ThinkingLevelSource do
  @moduledoc """
  Picker source for AI agent thinking levels.

  Presents the supported provider levels and marks the current level so `SPC a T` shows the available choices instead of cycling blindly.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @levels [
    {"off", "No additional reasoning effort"},
    {"low", "Low reasoning effort"},
    {"medium", "Medium reasoning effort"},
    {"high", "High reasoning effort"}
  ]

  @impl true
  @spec title() :: String.t()
  def title, do: "Agent Thinking"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec layout() :: MingaEditor.UI.Picker.Source.layout()
  def layout, do: :centered

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{picker_ui: %{context: %{current_level: current_level}}}) do
    Enum.map(@levels, &format_level(&1, current_level))
  end

  def candidates(_context) do
    Enum.map(@levels, &format_level(&1, nil))
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: level}, state) when is_binary(level) do
    MingaEditor.Commands.Agent.set_thinking_level(state, level)
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec format_level({String.t(), String.t()}, String.t() | nil) :: Item.t()
  defp format_level({level, description}, current_level) do
    %Item{
      id: level,
      label: display_name(level),
      description: description,
      active: level == current_level
    }
  end

  @spec display_name(String.t()) :: String.t()
  defp display_name("off"), do: "Off"
  defp display_name("low"), do: "Low"
  defp display_name("medium"), do: "Medium"
  defp display_name("high"), do: "High"
  defp display_name(level), do: String.capitalize(level)
end
