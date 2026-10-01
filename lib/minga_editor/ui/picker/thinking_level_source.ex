defmodule MingaEditor.UI.Picker.ThinkingLevelSource do
  @moduledoc """
  Picker source for reasoning controls supported by the active resolved route.

  Unsupported effort levels are never offered.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.ModelSelection
  alias MingaAgent.Session
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item

  @descriptions %{
    "off" => "No additional reasoning effort",
    "low" => "Low reasoning effort",
    "medium" => "Medium reasoning effort",
    "high" => "High reasoning effort"
  }
  @level_order ["off", "low", "medium", "high"]

  @impl true
  @spec title() :: String.t()
  def title, do: "Agent Thinking"

  @impl true
  @spec layout() :: MingaEditor.UI.Picker.Source.layout()
  def layout, do: :centered

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{agent_session: session} = context) when is_pid(session) do
    case Session.model_selection(session) do
      %ModelSelection{} = selection ->
        reasoning = selection.policy.reasoning
        Enum.map(reasoning.options, &format_level(&1, reasoning.effort))

      nil ->
        candidates_without_selection(context)
    end
  end

  def candidates(context), do: candidates_without_selection(context)

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: level}, state) when is_binary(level) do
    MingaEditor.Commands.Agent.set_thinking_level(state, level)
  end

  @spec format_level(String.t(), String.t() | nil) :: Item.t()
  defp format_level(level, current_level) do
    %Item{
      id: level,
      label: display_name(level),
      description: Map.get(@descriptions, level, "Provider-specific reasoning control"),
      active: level == current_level
    }
  end

  @spec candidates_without_selection(Context.t()) :: [Item.t()]
  defp candidates_without_selection(%Context{
         picker_ui: %{context: %{current_level: current_level}}
       }) do
    Enum.map(@level_order, &format_level(&1, current_level))
  end

  defp candidates_without_selection(_context), do: []

  @spec display_name(String.t()) :: String.t()
  defp display_name("off"), do: "Off"
  defp display_name("low"), do: "Low"
  defp display_name("medium"), do: "Medium"
  defp display_name("high"), do: "High"
  defp display_name(level), do: String.capitalize(level)
end
