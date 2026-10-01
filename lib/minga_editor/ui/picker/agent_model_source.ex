defmodule MingaEditor.UI.Picker.AgentModelSource do
  @moduledoc """
  Picker source for exact executable model routes.

  Items retain the immutable resolved selection in opaque picker metadata.
  Labels identify the model while descriptions expose protocol, endpoint,
  credential profile, verification status, limits, thinking controls, and
  favorite state without ever displaying credential values.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
  alias MingaAgent.Session
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  @impl true
  @spec title() :: String.t()
  def title, do: "Agent Model"

  @impl true
  @spec layout() :: MingaEditor.UI.Picker.Source.layout()
  def layout, do: :centered

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(%Context{agent_session: session}) do
    with true <- is_pid(session),
         {:ok, candidates} when is_list(candidates) <- fetch_models(session) do
      Enum.map(candidates, &format_candidate/1)
    else
      _ -> []
    end
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{meta: %{selection: %ModelSelection{} = selection}}, state) do
    MingaEditor.Commands.Agent.set_model(state, selection)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec fetch_models(pid()) :: {:ok, [ModelCandidate.t()]} | {:error, term()}
  defp fetch_models(session), do: Session.get_available_models(session)

  @spec format_candidate(ModelCandidate.t()) :: Item.t()
  defp format_candidate(%ModelCandidate{selection: selection} = candidate) do
    route = selection.route

    status =
      if selection.evidence.custom,
        do: "unverified custom route",
        else: "unverified catalog route"

    endpoint = endpoint_label(route.execution.base_url, route.execution.path)
    context = format_context(selection.policy.limits.context)
    cost = format_cost(selection.policy.cost)
    thinking = format_thinking(selection)
    capabilities = format_capabilities(selection)
    credential = ModelSelection.credential_id(selection.credential)

    description =
      [
        "#{route.model_provider} via #{route.execution.wire_protocol}",
        endpoint,
        credential,
        status,
        context,
        thinking,
        capabilities,
        cost
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    %Item{
      id: ModelSelection.id(selection),
      label: route.display_name,
      description: description,
      annotation: if(candidate.favorite, do: "★ favorite", else: nil),
      search_text:
        "#{route.model_provider} #{route.model_id} #{route.execution.wire_protocol} #{endpoint} #{credential}",
      two_line: true,
      active: candidate.current,
      meta: %{selection: selection}
    }
  end

  @spec format_cost(map() | nil) :: String.t()
  defp format_cost(%{"input" => input, "output" => output})
       when is_number(input) and is_number(output),
       do: "$#{input}/#{output} per MTok"

  defp format_cost(%{input: input, output: output})
       when is_number(input) and is_number(output),
       do: "$#{input}/#{output} per MTok"

  defp format_cost(_cost), do: ""

  @spec format_capabilities(ModelSelection.t()) :: String.t()
  defp format_capabilities(%ModelSelection{policy: %{capabilities: capabilities}}) do
    tools = capability_label(capabilities.tools)
    images = capability_label(capabilities.images)
    streaming = capability_label(capabilities.streaming)
    "tools #{tools}, images #{images}, streaming #{streaming}"
  end

  @spec capability_label(ModelSelection.capability()) :: String.t()
  defp capability_label(true), do: "yes"
  defp capability_label(false), do: "no"
  defp capability_label(:unknown), do: "unknown"

  @spec format_context(integer() | nil) :: String.t()
  defp format_context(nil), do: ""

  defp format_context(ctx) when is_integer(ctx) and ctx >= 1000 do
    "#{div(ctx, 1000)}k ctx"
  end

  defp format_context(_), do: ""

  @spec endpoint_label(String.t(), String.t()) :: String.t()
  defp endpoint_label(endpoint, path) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        base_path = String.trim_trailing(uri.path || "", "/")
        route_path = String.trim_leading(path, "/")
        URI.to_string(%{uri | path: "#{base_path}/#{route_path}"})

      _invalid ->
        endpoint
    end
  end

  @spec format_thinking(ModelSelection.t()) :: String.t()
  defp format_thinking(%ModelSelection{policy: %{reasoning: %{options: [_only]}}}),
    do: "thinking fixed"

  defp format_thinking(%ModelSelection{} = selection) do
    reasoning = selection.policy.reasoning
    "thinking #{reasoning.effort} (#{Enum.join(reasoning.options, "/")})"
  end
end
