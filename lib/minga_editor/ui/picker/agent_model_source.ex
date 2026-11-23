defmodule MingaEditor.UI.Picker.AgentModelSource do
  @moduledoc """
  Shared model and connection actions for one captured workspace and Session target.

  Catalog work runs outside the Editor. Once a listed model can be used, the chooser lists the models, any setup operation in progress, and one "Connect another provider…" row that opens `AgentConnectionSource` as a child picker. Until then, and when the catalog is unavailable, the connection actions stay in this list. Every item retains its original target because the picker closes before invoking its selection callback.

  Model rows are grouped by route: the route name ("ChatGPT", "Claude (subscription)") is the item's group, which frontends draw once as a section header, so the row description does not repeat it. The route name stays searchable. Connection rows follow the models in their own groups ("Setup in progress", "Connections").
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
  alias MingaAgent.Credentials.Snapshot, as: CredentialSnapshot
  alias MingaAgent.ModelSelection.Credential.ApiKey
  alias MingaAgent.ModelSelection.Credential.OAuth
  alias MingaAgent.Session
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.ConnectionTarget
  alias MingaEditor.Agent.ConnectionAction
  alias MingaEditor.Agent.UIState
  alias MingaEditor.PickerUI
  alias MingaAgent.InferenceRoute.PlanWindow
  alias MingaAgent.InferenceRoute.Status, as: InferenceRouteStatus
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.AgentConnectionSource
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

  The new fetch reads the registry and the Session's last discovery without checking any route again, so a usage report never starts another availability probe. A change that arrives while a fetch is in flight is listed after that fetch lands, because the fetch may have read its rows before the change. A change that arrives while the "Connect a provider" child picker is open is listed when Escape returns to the chooser. The query and the selected item stay.
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

      {:parent, origin} ->
        PickerUI.update_picker(
          state,
          &MingaEditor.State.Picker.put_parent_context(&1, %{origin | route_status: :changed})
        )

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
          {:ok, map(), MingaEditor.State.Picker.load_status()} | {:parent, map()} | :closed
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

  # The chooser waits behind its "Connect a provider" child picker.
  defp open_origin(%{
         shell_runtime: %{
           state: %{
             modal:
               {:picker,
                %{
                  picker_ui: %{
                    parent: %{
                      source: __MODULE__,
                      context: %{catalog: _catalog, route_status: _status} = origin
                    }
                  }
                }}
           }
         }
       }),
       do: {:parent, origin}

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
    case fetch_models(Map.get(origin, :catalog, :discover), target.session) do
      {:ok, models, notice, validity} when is_list(models) ->
        items =
          Enum.map(models, &with_origin(format_candidate(&1), origin, {:model, &1.selection}))

        {:ok, items ++ connection_items(origin, models),
         discovery_meta(target.session, notice, validity, origin.connection)}

      {:error, _reason} ->
        {:ok, connection_items(origin, []),
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

  # "Connect another provider…" opens the connection actions as a child picker; Escape returns here.
  @impl true
  @spec selection_disposition(Item.t(), map()) :: Source.selection_disposition()
  def selection_disposition(%Item{meta: %{intent: {:connections, connected}}}, origin) do
    context =
      origin
      |> Map.take([:workspace_id, :target, :connection, :connection_prompt])
      |> Map.put(:connected, connected)

    {:stay_open, {:nested, AgentConnectionSource, context}}
  end

  def selection_disposition(%Item{}, _origin), do: :accept

  @impl true
  @spec on_select(Item.t(), EditorState.t()) :: EditorState.t()
  def on_select(
        %Item{meta: %{workspace_id: id, target: target, intent: {:model, _selection} = intent}},
        state
      ),
      do: ConnectionAction.schedule(state, id, target, intent)

  def on_select(%Item{} = item, state), do: AgentConnectionSource.on_select(item, state)

  # Until a listed model can be used, the connection actions stay in this list as first-run setup.
  # After that, only a setup in progress stays here and the rest moves behind one row.
  @spec connection_items(map(), [ModelCandidate.t()]) :: [Item.t()]
  defp connection_items(origin, models) do
    if Enum.any?(models, &usable_model?/1) do
      connected = connected_credentials(models)
      AgentConnectionSource.pending_items(origin) ++ connect_another_item(origin, connected)
    else
      AgentConnectionSource.setup_items(origin, connected_credentials(models)) ++
        AgentConnectionSource.pending_items(origin)
    end
  end

  # A contributed route's model is usable once its route is ready; a catalog route is listed only
  # with a configured credential.
  @spec usable_model?(ModelCandidate.t()) :: boolean()
  defp usable_model?(%ModelCandidate{
         selection: %ModelSelection{route: %{request_provider: :contributed}},
         inference_route: %{status: status}
       }),
       do: InferenceRouteStatus.ready?(status)

  defp usable_model?(%ModelCandidate{}), do: true

  # The credentials that listed models use, so the connection actions offer account actions for
  # them instead of a first sign-in.
  @spec connected_credentials([ModelCandidate.t()]) :: CredentialSnapshot.t()
  defp connected_credentials(models) do
    credentials = Enum.map(models, & &1.selection.credential)

    api_keys =
      for %ApiKey{provider: provider, source: source} <- credentials,
          into: %{},
          do: {provider, source}

    CredentialSnapshot.new(api_keys, Enum.find(credentials, &match?(%OAuth{}, &1)))
  end

  @spec connect_another_item(map(), CredentialSnapshot.t()) :: [Item.t()]
  defp connect_another_item(%{target: %{session: session}} = origin, connected)
       when node(session) == node() do
    item = %Item{
      id: {:connection, :connect_another_provider},
      label: "Connect another provider…",
      description: "Sign in, manage API keys, or retry the connection.",
      search_text: "connect another provider sign in login api key retry",
      group: "Connections"
    }

    [with_origin(item, origin, {:connections, connected})]
  end

  defp connect_another_item(_remote, _connected), do: []

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

  # A contributed route's readiness and plan usage live in the status chip, and its name is the row's
  # group. The description names the account, remedy or plan reset, then the model's details.
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
      group: route_name,
      search_text: "#{route_name} #{route.model_provider} #{route.model_id}",
      active: candidate.current
    }
  end

  # A catalog route is listed only when its credential is configured, so its chip says it is
  # ready. The route is the row's group. The description shows the price and context; only a
  # capability the model lacks is named.
  defp format_candidate(%ModelCandidate{selection: selection} = candidate) do
    route = selection.route
    policy = selection.policy
    endpoint = endpoint_label(route.execution.base_url, route.execution.path)
    credential = ModelSelection.credential_id(selection.credential)
    route_name = catalog_route_name(route.request_provider)

    description =
      [
        metered_cost(policy),
        format_context(policy.limits.context),
        catalog_thinking(selection),
        catalog_limitations(selection)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    %Item{
      id: ModelSelection.id(selection),
      label: route.display_name,
      description: description,
      annotation: if(candidate.favorite, do: "★ favorite", else: nil),
      status: Status.new(:ready, "Ready"),
      group: route_name,
      search_text:
        "#{route_name} #{route.model_provider} #{route.model_id} #{route.execution.wire_protocol} #{endpoint} #{credential}",
      active: candidate.current
    }
  end

  @spec catalog_route_name(ModelSelection.Route.request_provider()) :: String.t()
  defp catalog_route_name(:apple), do: "On device"
  defp catalog_route_name(:openai_codex), do: "ChatGPT"
  defp catalog_route_name(provider), do: "#{provider} API"

  @spec catalog_thinking(ModelSelection.t()) :: String.t()
  defp catalog_thinking(%ModelSelection{route: %{request_provider: :apple}}),
    do: "no thinking controls"

  defp catalog_thinking(selection), do: compact_thinking(selection)

  # Apple's on-device model has its own compact tool set and sends instruction files only when
  # they fit its context. Other routes name only what they lack.
  @spec catalog_limitations(ModelSelection.t()) :: String.t()
  defp catalog_limitations(%ModelSelection{route: %{request_provider: :apple}}),
    do: "compact file tools, no images, instruction files only if they fit"

  defp catalog_limitations(%ModelSelection{policy: %{capabilities: capabilities}}) do
    [tools: capabilities.tools, images: capabilities.images]
    |> Enum.filter(fn {_name, supported} -> supported == false end)
    |> Enum.map_join(", ", fn {name, false} -> "no #{name}" end)
  end

  @spec format_cost(map() | nil) :: String.t()
  defp format_cost(%{"input" => input, "output" => output})
       when is_number(input) and is_number(output),
       do: "$#{input}/#{output} per MTok"

  defp format_cost(%{input: input, output: output})
       when is_number(input) and is_number(output),
       do: "$#{input}/#{output} per MTok"

  defp format_cost(_cost), do: ""

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

  defp route_status(status, _policy), do: AgentConnectionSource.availability_status(status)

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
end
