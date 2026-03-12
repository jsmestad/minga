defmodule Minga.Picker.AgentModelSource do
  @moduledoc """
  Picker source for AI agent models.

  Fetches available models from the running pi RPC session and presents
  them for selection. Selecting a model switches the agent to use it via
  `set_model` on the pi backend.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Agent.Session
  alias Minga.Editor.State.AgentAccess

  @impl true
  @spec title() :: String.t()
  def title, do: "Agent Model"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: false

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(state) do
    session = AgentAccess.session(state)

    with true <- is_pid(session),
         {:ok, %{"models" => models}} when is_list(models) <-
           Session.get_available_models(session) do
      Enum.map(models, &format_model/1)
    else
      _ -> []
    end
  end

  @spec format_model(map()) :: Minga.Picker.item()
  defp format_model(model) do
    id = model["id"] || "unknown"
    provider = model["provider"] || "unknown"
    name = model["name"] || id
    cost_info = format_cost(model["cost"])

    {{provider, id}, "#{name}", "#{provider} #{cost_info}"}
  end

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
