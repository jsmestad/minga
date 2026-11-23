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
  alias MingaAgent.InferenceRoute.PlanWindow
  alias MingaAgent.InferenceRoute.Spec, as: InferenceRouteSpec
  alias MingaAgent.InferenceRoute.Status, as: InferenceRouteStatus
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Item.Status
  alias MingaEditor.UI.Picker.Source
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
          connection_prompt: state.workspace.agent_ui.connection_prompt,
          catalog: :discover,
          route_status: :current
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

  @doc """
  Lists the open chooser's rows again after a contributed route's status or plan usage changed.

  The new fetch reads the registry and the Session's last discovery without checking any route again, so a usage report never starts another availability probe. A change that arrives while a fetch is in flight is listed after that fetch lands, because the fetch may have read its rows before the change. The query and the selected item stay.
  """
  @spec route_status_changed(EditorState.t()) :: EditorState.t()
  def route_status_changed(state) do
    case open_origin(state) do
      {:ok, origin, :loading} ->
        put_origin(state, %{origin | route_status: :changed})

      {:ok, origin, _settled} ->
        state
        |> put_origin(%{origin | catalog: :listed, route_status: :current})
        |> PickerUI.refresh_items()

      :closed ->
        state
    end
  end

  @doc "Lists the rows again when a route status change arrived while the fetch that just landed was running."
  @spec relist_after_fetch(EditorState.t()) :: EditorState.t()
  def relist_after_fetch(state) do
    case open_origin(state) do
      {:ok, %{route_status: :changed}, _load_status} -> route_status_changed(state)
      _current_or_closed -> state
    end
  end

  @spec open_origin(EditorState.t()) ::
          {:ok, map(), MingaEditor.State.Picker.load_status()} | :closed
  defp open_origin(%{
         shell_runtime: %{
           state: %{
             modal:
               {:picker,
                %{
                  picker_ui: %{
                    source: __MODULE__,
                    context: %{catalog: _catalog, route_status: _status} = origin,
                    load_status: load_status
                  }
                }}
           }
         }
       }),
       do: {:ok, origin, load_status}

  defp open_origin(_state), do: :closed

  @spec put_origin(EditorState.t(), map()) :: EditorState.t()
  defp put_origin(state, origin),
    do: PickerUI.update_picker(state, &MingaEditor.State.Picker.put_context(&1, origin))

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
  @spec async_fetch(Context.t()) :: {:ok, [Item.t()], Source.fetch_meta()} | {:error, String.t()}
  def async_fetch(%Context{
        picker_ui: %{context: %{target: %ConnectionTarget{} = target} = origin}
      }) do
    actions = connection_actions(origin)

    case fetch_models(Map.get(origin, :catalog, :discover), target.session) do
      {:ok, models, notice, validity} when is_list(models) ->
        items =
          Enum.map(models, &with_origin(format_candidate(&1), origin, {:model, &1.selection}))

        {:ok, route_setup_items(origin) ++ items ++ actions,
         discovery_meta(target.session, notice, validity, origin.connection)}

      {:error, _reason} ->
        {:ok, actions,
         %{status: "Model catalog is unavailable. Connection actions are still available."}}
    end
  end

  def async_fetch(_context),
    do: {:error, "The original connection is unavailable. Reopen the agent workspace."}

  @doc "Drops superseded runtime-gated rows and their notice without removing connection actions."
  @spec for_publication(
          {:ok, [Item.t()], [Candidate.t()], Source.fetch_meta()},
          pid() | nil
        ) :: {:ok, [Item.t()], [Candidate.t()], Source.fetch_meta()}
  def for_publication(
        {:ok, items, candidates, %{model_discovery: {owner, validity}}} = result,
        session
      ) do
    if owner == session and Session.model_discovery_current?(owner, validity) do
      result
    else
      {:ok, Enum.reject(items, &discovered_item?/1),
       Enum.reject(candidates, &discovered_item?(&1.item)), %{}}
    end
  end

  def for_publication(result, _session), do: result

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

  # The route check runs on the connection effect worker; the notice shows it is in progress.
  def on_select(
        %Item{
          meta: %{
            workspace_id: id,
            target: target,
            intent: {:check_route, _route_id, name} = intent
          }
        },
        state
      ) do
    state
    |> NoticeWorkflow.publish("Checking #{name}…")
    |> ConnectionAction.schedule(id, target, intent)
  end

  def on_select(%Item{meta: %{workspace_id: id, target: target, intent: intent}}, state),
    do: ConnectionAction.schedule(state, id, target, intent)

  # Setup rows come from the registry in this fetch worker, after discovery refreshed route availability.
  @spec route_setup_items(map()) :: [Item.t()]
  defp route_setup_items(%{target: %{session: session}} = origin) when node(session) == node() do
    # minga:allow-blocking — only async_fetch/1 calls this, in the picker fetch worker (async?/0 is true)
    case Session.inference_route_setups(session) do
      {:ok, entries} ->
        Enum.map(entries, fn entry ->
          intent = {:check_route, entry.spec.id, InferenceRouteSpec.short_name(entry.spec)}
          with_origin(setup_item(entry), origin, intent)
        end)

      {:error, :unsupported} ->
        []
    end
  end

  defp route_setup_items(_remote), do: []

  # The chip shows readiness; the description keeps the action's own words and the account or
  # remedy.
  @spec setup_item(MingaAgent.InferenceRouteRegistry.Entry.t()) :: Item.t()
  defp setup_item(%{spec: %{setup_action: action} = spec, status: status}) do
    %Item{
      id: {:route_setup, spec.id},
      label: action.label,
      description: "#{action.description} · #{setup_detail(status)}",
      status: availability_status(status),
      search_text: "#{action.label} #{spec.display_name} setup"
    }
  end

  @spec setup_detail(InferenceRouteStatus.t()) :: String.t()
  defp setup_detail(%{availability: {:ready, account}}), do: account
  defp setup_detail(status), do: setup_readiness(status)

  @doc "Describes a route's readiness for its setup row, using the route's own account and remedy text."
  @spec setup_readiness(MingaAgent.InferenceRoute.Status.t()) :: String.t()
  def setup_readiness(%{availability: {:ready, account}}), do: "Ready: #{account}"
  def setup_readiness(%{availability: {:unavailable, _reason, remedy}}), do: remedy
  def setup_readiness(%{availability: :unknown}), do: "Select to check"

  @spec discovery_meta(
          pid(),
          String.t() | :superseded | :listed | nil,
          :atomics.atomics_ref() | nil,
          ConnectionSnapshot.t()
        ) ::
          Source.fetch_meta()
  defp discovery_meta(_session, :superseded, nil, _connection), do: %{}

  # A relisting keeps the notice of the discovery that opened the chooser.
  defp discovery_meta(_session, :listed, nil, _connection), do: %{}

  defp discovery_meta(_session, nil, nil, connection), do: %{status: connection_label(connection)}

  defp discovery_meta(session, notice, validity, connection),
    do: %{status: notice || connection_label(connection), model_discovery: {session, validity}}

  @spec discovered_item?(Item.t()) :: boolean()
  defp discovered_item?(%Item{
         meta: %{intent: {:model, %ModelSelection{route: %{request_provider: provider}}}}
       }),
       do: provider in [:apple, :openai_codex, :contributed]

  defp discovered_item?(%Item{}), do: false

  @spec fetch_models(:discover | :listed, pid()) ::
          {:ok, term(), String.t() | :superseded | :listed | nil, :atomics.atomics_ref() | nil}
          | {:error, term()}
  defp fetch_models(:discover, session) when node(session) == node() do
    # minga:allow-blocking — only async_fetch/1 calls this, in the picker fetch worker (async?/0 is true)
    Session.discover_available_models(session)
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  # Relisting reads the last discovery and the registry's current route status; no route is checked.
  defp fetch_models(:listed, session) do
    # minga:allow-blocking — only async_fetch/1 calls this, in the picker fetch worker (async?/0 is true)
    with {:ok, models} <- Session.get_available_models(session), do: {:ok, models, :listed, nil}
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  defp fetch_models(:discover, session) do
    # minga:allow-blocking — only async_fetch/1 calls this, in the picker fetch worker (async?/0 is true)
    with {:ok, models} <- Session.get_available_models(session), do: {:ok, models, nil, nil}
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

  # A contributed route's readiness and plan usage live in the status chip. The description names
  # the route, then the account, remedy or plan reset, then the model's details.
  @spec format_candidate(ModelCandidate.t()) :: Item.t()
  defp format_candidate(
         %ModelCandidate{
           selection: %ModelSelection{route: %{request_provider: :contributed}} = selection,
           inference_route: %{display_name: route_name, status: status}
         } = candidate
       ) do
    route = selection.route
    policy = selection.policy

    description =
      [
        route_name,
        route_detail(status, policy),
        metered_cost(policy),
        format_context(policy.limits.context),
        compact_thinking(selection),
        compact_capabilities(policy.capabilities)
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    %Item{
      id: ModelSelection.id(selection),
      label: route.display_name,
      description: description,
      annotation: if(candidate.favorite, do: "★ favorite", else: nil),
      status: route_status(status, policy),
      search_text: "#{route_name} #{route.model_provider} #{route.model_id}",
      active: candidate.current
    }
  end

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
        evidence_label(route.request_provider),
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
  defp format_capabilities(%ModelSelection{route: %{request_provider: :apple}}),
    do: "Compact file tools · no images"

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

  # Plan usage at or above this percentage of the busiest window warns before the limit is reached.
  @warn_percent 80

  @typep plan_state ::
           :checking
           | :unreported
           | {:limit_reached, PlanWindow.t()}
           | {:near_limit, PlanWindow.t()}
           | {:within_limit, PlanWindow.t()}

  # The chip for a contributed model route: readiness and the busiest plan window's usage. A ready
  # subscription route measures its plan beside the availability check, so until its first usage
  # report the chip says the check is under way. Metered routes have no plan to report. A reached
  # limit is an error, but the row stays selectable.
  @spec route_status(InferenceRouteStatus.t(), ModelSelection.Policy.t()) :: Status.t()
  defp route_status(%InferenceRouteStatus{availability: {:ready, _account}} = status, policy) do
    case plan_state(status, policy) do
      :checking -> Status.new(:checking, "Checking…")
      :unreported -> Status.new(:ready, "Ready")
      {:limit_reached, _window} -> Status.new(:error, "Limit reached")
      {:near_limit, window} -> Status.new(:warn, "Ready · #{PlanWindow.percent(window)}%")
      {:within_limit, window} -> Status.new(:ready, "Ready · #{PlanWindow.percent(window)}%")
    end
  end

  defp route_status(status, _policy), do: availability_status(status)

  @spec availability_status(InferenceRouteStatus.t()) :: Status.t()
  defp availability_status(%{availability: {:ready, _account}}), do: Status.new(:ready, "Ready")

  defp availability_status(%{availability: {:unavailable, _reason, _remedy}}),
    do: Status.new(:error, "Unavailable")

  defp availability_status(%{availability: :unknown}), do: Status.new(:neutral, "Not checked")

  # The account with the plan detail the chip leaves out, the remedy, or only the plan detail when
  # unchecked.
  @spec route_detail(InferenceRouteStatus.t(), ModelSelection.Policy.t()) :: [String.t()]
  defp route_detail(%InferenceRouteStatus{availability: {:ready, account}} = status, policy),
    do: [account, plan_detail(plan_state(status, policy))]

  defp route_detail(%{availability: {:unavailable, _reason, remedy}}, _policy), do: [remedy]

  defp route_detail(%InferenceRouteStatus{availability: :unknown} = status, policy),
    do: [plan_detail(plan_state(status, policy))]

  @spec plan_detail(plan_state()) :: String.t()
  defp plan_detail(:checking), do: "checking plan usage"
  defp plan_detail(:unreported), do: ""
  defp plan_detail({_state, window}), do: window_reset_label(window)

  @spec plan_state(InferenceRouteStatus.t(), ModelSelection.Policy.t()) :: plan_state()
  defp plan_state(%InferenceRouteStatus{plan_usage: :unreported} = status, policy) do
    if awaits_plan_usage?(status, policy), do: :checking, else: :unreported
  end

  defp plan_state(status, _policy) do
    windows = InferenceRouteStatus.plan_windows(status)

    case {PlanWindow.rejected(windows), PlanWindow.busiest(windows)} do
      {nil, nil} -> :unreported
      {%PlanWindow{} = rejected, _busiest} -> {:limit_reached, rejected}
      {nil, window} -> usage_state(window, PlanWindow.percent(window))
    end
  end

  @spec usage_state(PlanWindow.t(), non_neg_integer()) :: plan_state()
  defp usage_state(window, percent) when percent >= 100, do: {:limit_reached, window}
  defp usage_state(window, percent) when percent >= @warn_percent, do: {:near_limit, window}
  defp usage_state(window, _percent), do: {:within_limit, window}

  @spec awaits_plan_usage?(InferenceRouteStatus.t(), ModelSelection.Policy.t()) :: boolean()
  defp awaits_plan_usage?(status, %{cost_mode: :subscription}),
    do: InferenceRouteStatus.ready?(status)

  defp awaits_plan_usage?(_status, _policy), do: false

  # "5h limit resets 3:40 PM", or "5h limit" when the route does not know the reset time.
  @spec window_reset_label(PlanWindow.t()) :: String.t()
  defp window_reset_label(window) do
    limit = "#{PlanWindow.kind_label(window.kind)} limit"

    case MingaAgent.InferenceRouteRegistry.reset_label(window) do
      nil -> limit
      reset -> "#{limit} resets #{reset}"
    end
  end

  # Subscription routes are paid by the plan the chip reports, so only metered routes show a price.
  @spec metered_cost(ModelSelection.Policy.t()) :: String.t()
  defp metered_cost(%{cost_mode: :subscription}), do: ""
  defp metered_cost(%{cost: cost}), do: format_cost(cost)

  @spec compact_thinking(ModelSelection.t()) :: String.t()
  defp compact_thinking(%ModelSelection{policy: %{reasoning: %{options: [_only]}}}),
    do: "thinking fixed"

  defp compact_thinking(%ModelSelection{policy: %{reasoning: reasoning}}),
    do: "thinking #{reasoning.effort}"

  # Supported capabilities by name, such as "tools, images, streaming"; others say "no images" or
  # "images unknown".
  @spec compact_capabilities(map()) :: String.t()
  defp compact_capabilities(capabilities) do
    [tools: capabilities.tools, images: capabilities.images, streaming: capabilities.streaming]
    |> Enum.map_join(", ", fn
      {name, true} -> "#{name}"
      {name, false} -> "no #{name}"
      {name, :unknown} -> "#{name} unknown"
    end)
  end

  @spec evidence_label(ModelSelection.Route.request_provider()) :: String.t()
  defp evidence_label(:apple), do: "Ready on this device"
  defp evidence_label(_provider), do: "unverified catalog route"

  @spec endpoint_label(String.t() | nil, String.t() | nil) :: String.t()
  defp endpoint_label(nil, nil), do: "On device"

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
  defp format_thinking(%ModelSelection{route: %{request_provider: :apple}}),
    do: "No thinking controls"

  defp format_thinking(%ModelSelection{policy: %{reasoning: %{options: [_only]}}}),
    do: "thinking fixed"

  defp format_thinking(%ModelSelection{} = selection) do
    reasoning = selection.policy.reasoning
    "thinking #{reasoning.effort} (#{Enum.join(reasoning.options, "/")})"
  end
end
