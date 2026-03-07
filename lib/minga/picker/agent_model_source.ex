defmodule Minga.Picker.AgentModelSource do
  @moduledoc """
  Picker source for AI agent models.

  Fetches available models from the running pi RPC session and presents
  them for selection. Selecting a model switches the agent to use it via
  `set_model` on the pi backend.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Agent.Session

  @impl true
  @spec title() :: String.t()
  def title, do: "Agent Model"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(%{agent_session: session}) when is_pid(session) do
    case Session.get_available_models(session) do
      {:ok, %{"models" => models}} when is_list(models) ->
        Enum.map(models, fn model ->
          id = model["id"] || "unknown"
          provider = model["provider"] || "unknown"
          name = model["name"] || id
          cost_info = format_cost(model["cost"])

          {
            {provider, id},
            "#{name}",
            "#{provider} #{cost_info}"
          }
        end)

      _ ->
        []
    end
  end

  def candidates(_state), do: []

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({{provider, model_id}, _label, _desc}, state) do
    Minga.Editor.Commands.Agent.set_provider(
      Minga.Editor.Commands.Agent.set_model(state, model_id),
      provider
    )
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  @spec format_cost(map() | nil) :: String.t()
  defp format_cost(%{"input" => input, "output" => output}) do
    "$#{input}/#{output} per MTok"
  end

  defp format_cost(_), do: ""
end
