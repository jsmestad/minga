defmodule MingaEditor.UI.Picker.AgentModelSource do
  @moduledoc """
  Shared model and connection actions for one captured workspace and Session target.

  Catalog work runs outside the Editor. Connection actions remain available when the catalog is empty or unavailable. Every item retains its original target because the picker closes before invoking its selection callback.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
  alias MingaAgent.Session
  alias MingaAgent.Credentials
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.ConnectionTarget
  alias MingaEditor.Agent.ConnectionAction
  alias MingaEditor.Agent.ConnectionPrompt
  alias MingaEditor.Agent.ConnectionSetup
  alias MingaEditor.Agent.UIState
  alias MingaEditor.PickerUI
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  @impl true
  @spec title() :: String.t()
  def title, do: "Models and connections"

  @impl true
  @spec layout() :: MingaEditor.UI.Picker.Source.layout()
  def layout, do: :centered

  @doc "Opens the shared chooser with immutable origin metadata."
  @spec open(EditorState.t()) :: EditorState.t()
  def open(state) do
    case ConnectionAction.origin(state) do
      {:ok, workspace_id, connection} ->
        PickerUI.open(state, __MODULE__, %{
          workspace_id: workspace_id,
          target: connection.target,
          connection: connection,
          connection_prompt: state.workspace.agent_ui.connection_prompt
        })

      {:error, :connection_unavailable} ->
        ui =
          UIState.push_toast(
            state.workspace.agent_ui,
            "Connection details are unavailable. Reopen the agent workspace.",
            :error
          )

        Workflow.install_agent_ui(state, ui)
    end
  end

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(context) do
    case async_fetch(context) do
      {:ok, items, _metadata} -> items
      {:error, _message} -> []
    end
  end

  @impl true
  @spec async_fetch(Context.t()) :: {:ok, [Item.t()], map()} | {:error, String.t()}
  def async_fetch(%Context{
        picker_ui: %{context: %{target: %ConnectionTarget{} = target} = origin}
      }) do
    actions = connection_actions(origin)

    case fetch_models(target.session) do
      {:ok, models} ->
        items =
          Enum.map(models, &with_origin(format_candidate(&1), origin, {:model, &1.selection}))

        {:ok, items ++ actions, %{status: connection_label(origin.connection)}}

      {:error, _reason} ->
        {:ok, actions,
         %{status: "Model catalog is unavailable. Connection actions are still available."}}
    end
  end

  def async_fetch(_context),
    do: {:error, "The original connection is unavailable. Reopen the agent workspace."}

  @impl true
  @spec on_select(Item.t(), EditorState.t()) :: EditorState.t()
  def on_select(
        %Item{meta: %{workspace_id: id, target: target, intent: {:connect, method}}},
        state
      ),
      do: ConnectionSetup.start(state, id, target, method)

  def on_select(
        %Item{meta: %{intent: {:authorization_url, action, %ConnectionPrompt{} = prompt}}},
        state
      ),
      do: ConnectionSetup.authorization_url(state, prompt, action)

  def on_select(%Item{meta: %{intent: {:resume, %ConnectionPrompt{} = prompt}}}, state),
    do: ConnectionSetup.resume(state, prompt)

  def on_select(%Item{meta: %{workspace_id: id, target: target, intent: intent}}, state),
    do: ConnectionAction.schedule(state, id, target, intent)

  @spec discovery_meta(pid(), String.t() | nil, :atomics.atomics_ref() | nil) ::
          MingaEditor.UI.Picker.Source.fetch_meta()
  defp discovery_meta(_session, nil, nil), do: %{}
  defp discovery_meta(session, nil, validity), do: %{model_discovery: {session, validity}}

  defp discovery_meta(session, notice, validity),
    do: %{model_discovery: {session, validity}, status: notice}

  @spec codex_item?(Item.t()) :: boolean()
  defp codex_item?(%Item{meta: %{selection: %{route: %{request_provider: :openai_codex}}}}),
    do: true

  defp codex_item?(%Item{}), do: false

  @spec fetch_models(pid()) :: {:ok, [ModelCandidate.t()]} | {:error, term()}
  defp fetch_models(session) do
    Session.get_available_models(session)
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  @spec connection_actions(map()) :: [Item.t()]
  defp connection_actions(%{target: %{session: session}} = origin) when node(session) == node() do
    setup = setup_actions()

    retry = [
      {"Retry current connection", :retry, "Recheck credentials without sending your draft."}
    ]

    cancel =
      case origin.connection.operation do
        {:connecting, ref} ->
          [
            {"Cancel connection setup", {:cancel, ref},
             "Cancel only this offered setup operation."}
          ]

        :idle ->
          []
      end

    resume = resume_action(origin.connection_prompt, origin.connection)
    authorization = authorization_actions(origin.connection_prompt, origin.connection)

    Enum.map(setup ++ retry ++ cancel ++ authorization ++ resume, fn {label, intent, description} ->
      with_origin(
        %Item{
          id: {:connection, intent},
          label: label,
          description: description,
          search_text: label
        },
        origin,
        intent
      )
    end)
  end

  defp connection_actions(_remote), do: []

  @spec authorization_actions(ConnectionPrompt.t() | nil, ConnectionSnapshot.t()) ::
          [{String.t(), term(), String.t()}]
  defp authorization_actions(%ConnectionPrompt{authorization_url: url} = prompt, connection)
       when is_binary(url) do
    if ConnectionPrompt.current?(prompt, connection) do
      [
        {"Open authorization link", {:authorization_url, :open, prompt},
         "Open OpenAI in your browser."},
        {"Copy authorization link", {:authorization_url, :copy, prompt},
         "Use another browser or device."}
      ]
    else
      []
    end
  end

  defp authorization_actions(_prompt, _connection), do: []

  @spec resume_action(ConnectionPrompt.t() | nil, ConnectionSnapshot.t()) :: [
          {String.t(), term(), String.t()}
        ]
  defp resume_action(%ConnectionPrompt{} = prompt, connection) do
    if ConnectionPrompt.current?(prompt, connection) do
      label =
        if is_binary(prompt.authorization_url),
          do: "Resume OpenAI sign-in",
          else: "Resume API key entry"

      [
        {label, {:resume, prompt}, "Open a blank masked prompt for this operation."}
      ]
    else
      []
    end
  end

  defp resume_action(nil, _connection), do: []

  @spec setup_actions() :: [{String.t(), term(), String.t()}]
  defp setup_actions do
    oauth = [
      {"Sign in with ChatGPT", {:connect, :oauth_browser},
       "Open browser authorization without sending your draft."},
      {"Sign in with ChatGPT manually", {:connect, :oauth_manual},
       "Paste the redirect into masked input."}
    ]

    api_keys =
      Credentials.known_providers()
      |> Enum.filter(&(Credentials.env_var_for(&1) != nil))
      |> Enum.map(fn provider ->
        {"Connect #{provider} with API key", {:connect, {:api_key, provider}},
         "Masked input keeps your draft."}
      end)

    oauth ++ api_keys
  end

  @spec with_origin(Item.t(), map(), term()) :: Item.t()
  defp with_origin(item, origin, intent) do
    %{item | meta: %{workspace_id: origin.workspace_id, target: origin.target, intent: intent}}
  end

  @spec connection_label(ConnectionSnapshot.t()) :: String.t()
  defp connection_label(connection),
    do: connection |> ConnectionSnapshot.status() |> status_label()

  @spec status_label(atom()) :: String.t()
  defp status_label(:unconfigured),
    do: "Choose a model or connect a provider. Your draft will not be sent."

  defp status_label(:checking),
    do: "Checking local credentials. No provider request is made by this menu."

  defp status_label(:connecting), do: "Connecting. Your draft will not be sent."

  defp status_label(:ready),
    do: "Provider is running. Selecting a model does not send your draft."

  defp status_label(_status), do: "Connection needs attention. Connect a provider or retry."

  @spec format_candidate(ModelCandidate.t()) :: Item.t()
  defp format_candidate(%ModelCandidate{selection: selection} = candidate) do
    route = selection.route

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
        "unverified catalog route",
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
      active: candidate.current
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
