defmodule Minga.Picker.AgentModelSource do
  @moduledoc """
  Picker source for AI agent models.

  Fetches available models from the active agent session and presents
  them for selection. Works with both the pi-agent backend (which
  returns `%{"models" => [...]}`) and the native provider (which
  returns a flat list of model maps).

  Selecting a model sets it via `set_model` on the editor state, which
  restarts the session with the new model.
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
         {:ok, models} when is_list(models) <- fetch_models(session) do
      Enum.map(models, &format_model/1)
    else
      _ -> []
    end
  end

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({model_id, _label, _desc}, state) when is_binary(model_id) do
    # Native provider: model_id is the full "provider:model_name" string
    Minga.Editor.Commands.Agent.set_model(state, model_id)
  end

  def on_select({{provider, model_id}, _label, _desc}, state) do
    # Pi-agent backend: separate provider and model_id
    Minga.Editor.Commands.Agent.set_provider(
      Minga.Editor.Commands.Agent.set_model(state, model_id),
      provider
    )
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  # Handles both response formats:
  # - Native provider returns {:ok, [model_map, ...]}
  # - Pi-agent returns {:ok, %{"models" => [model_map, ...]}}
  @spec fetch_models(pid()) :: {:ok, [map()]} | {:error, term()}
  defp fetch_models(session) do
    case Session.get_available_models(session) do
      {:ok, %{"models" => models}} when is_list(models) -> {:ok, models}
      {:ok, models} when is_list(models) -> {:ok, models}
      other -> other
    end
  end

  @spec format_model(map()) :: Minga.Picker.item()
  defp format_model(model) do
    id = model["id"] || "unknown"
    provider = model["provider"] || "unknown"
    name = model["name"] || id
    cost_info = format_cost(model["cost"])
    context_info = format_context(model["context_window"])
    current_marker = if model["current"], do: " ★", else: ""

    desc = String.trim("#{provider}  #{context_info}  #{cost_info}#{current_marker}")

    {id, name, desc}
  end

  @spec format_cost(map() | nil) :: String.t()
  defp format_cost(%{"input" => input, "output" => output})
       when is_number(input) and is_number(output) do
    "$#{input}/#{output} per MTok"
  end

  defp format_cost(_), do: ""

  @spec format_context(integer() | nil) :: String.t()
  defp format_context(nil), do: ""

  defp format_context(ctx) when is_integer(ctx) and ctx >= 1000 do
    "#{div(ctx, 1000)}k ctx"
  end

  defp format_context(_), do: ""
end
