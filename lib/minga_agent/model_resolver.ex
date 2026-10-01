defmodule MingaAgent.ModelResolver do
  @moduledoc """
  Resolves boundary input into one exact executable `ModelSelection`.

  Catalog lookup and custom endpoint interpretation happen only at selection and restore boundaries.
  Restore validates the persisted exact route against its current source-owned declaration and never substitutes another route.
  """

  alias MingaAgent.Config
  alias MingaAgent.Credentials
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.{ApiKey, None, OAuth}
  alias MingaAgent.ModelSelection.{Evidence, Policy, Route, Stored, TextExecution}
  alias MingaAgent.Provider.Spec
  alias MingaAgent.ProviderRegistry

  @request_providers ~w(anthropic openai openai_codex google openrouter groq mistral deepseek ollama)a
  @request_provider_names Enum.map(@request_providers, &Atom.to_string/1)
  @reasoning_efforts ~w(off none minimal low medium high xhigh max)

  @type intent :: String.t() | map() | ModelSelection.t() | Stored.t() | nil
  @type context :: %{
          spec: Spec.t(),
          config: Config.t(),
          snapshot: Snapshot.t(),
          opts: keyword()
        }
  @type resolution_error ::
          :no_available_model
          | {:invalid_model_selection, String.t()}
          | {:model_not_found, String.t()}
          | {:backend_unavailable, String.t()}
          | {:credential_unavailable, String.t()}
          | {:route_unavailable, String.t()}
          | {:incompatible_selection, String.t()}
          | {:selection_correction_required, String.t()}

  @doc "Resolves raw config, picker, command, or migration input to one exact selection."
  @spec resolve(intent(), keyword()) :: {:ok, ModelSelection.t()} | {:error, resolution_error()}
  def resolve(intent, opts \\ []) do
    with {:ok, spec} <- backend_spec(opts) do
      context = %{
        spec: spec,
        config: Keyword.get(opts, :config, %Config{}),
        snapshot: Keyword.get_lazy(opts, :credential_snapshot, &Credentials.snapshot/0),
        opts: opts
      }

      resolve_with_context(intent, context)
    end
  end

  @doc "Validates persisted exact route data against its source without route substitution."
  @spec restore(map() | Stored.t() | ModelSelection.t(), keyword()) ::
          {:ok, ModelSelection.t()} | {:error, resolution_error()}
  def restore(value, opts \\ [])

  def restore(%ModelSelection{} = selection, opts) do
    selection
    |> ModelSelection.encode()
    |> restore(opts)
  end

  def restore(%Stored{} = stored, opts), do: restore_stored(stored, opts)

  def restore(data, opts) when is_map(data) do
    case ModelSelection.decode(string_key_map(data)) do
      {:ok, stored} -> restore_stored(stored, opts)
      {:error, reason} -> correction("Saved model selection is invalid: #{inspect(reason)}")
    end
  end

  @doc "Lists exact credential-backed executable routes suitable for the picker."
  @spec candidates(keyword()) :: [ModelCandidate.t()]
  def candidates(opts \\ []) do
    config = Keyword.get(opts, :config, %Config{})
    snapshot = Keyword.get_lazy(opts, :credential_snapshot, &Credentials.snapshot/0)
    favorites = Keyword.get(opts, :favorites, config.model_favorites)
    current_id = current_selection_id(Keyword.get(opts, :current))

    case backend_spec(opts) do
      {:ok, spec} ->
        build_candidates(%{
          spec: spec,
          config: config,
          snapshot: snapshot,
          favorites: canonical_favorites(favorites, spec, config, snapshot, opts),
          current_id: current_id,
          opts: opts
        })

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Model candidates unavailable: #{MingaAgent.Redaction.format_error(reason)}"
        )

        []
    end
  end

  @spec canonical_favorites(
          [String.t()],
          MingaAgent.Provider.Spec.t(),
          Config.t(),
          Snapshot.t(),
          keyword()
        ) :: [String.t()]
  defp canonical_favorites([], _spec, _config, _snapshot, _opts), do: []

  defp canonical_favorites(favorites, spec, config, snapshot, opts) do
    context = %{
      spec: spec,
      config: config,
      snapshot: snapshot,
      opts: Keyword.put(opts, :candidate_resolution, true)
    }

    Enum.flat_map(favorites, &canonical_favorite(&1, context))
  end

  @spec canonical_favorite(String.t(), map()) :: [String.t()]
  defp canonical_favorite("ms2_" <> _identity = favorite, _context), do: [favorite]

  defp canonical_favorite(favorite, context) do
    case resolve_with_context(favorite, context) do
      {:ok, selection} ->
        [ModelSelection.id(selection)]

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Favorite model requires correction: #{MingaAgent.Redaction.format_error(reason)}"
        )

        []
    end
  end

  @doc "Formats an actionable, secret-free resolution error."
  @spec message(resolution_error() | term()) :: String.t()
  def message({:invalid_model_selection, message}), do: message

  def message({:model_not_found, model}),
    do:
      "Model #{inspect(model)} is not in the executable catalog or an explicitly configured custom endpoint. Pick another model."

  def message({:backend_unavailable, backend}),
    do: "Agent backend #{inspect(backend)} is unavailable. Enable it or pick another backend."

  def message({:credential_unavailable, profile}),
    do:
      "Credential profile #{inspect(profile)} is missing, invalid, or was revoked. Re-authenticate that exact profile or pick another route."

  def message({:route_unavailable, message}), do: message
  def message({:incompatible_selection, message}), do: message
  def message({:selection_correction_required, message}), do: message

  def message(:no_available_model),
    do:
      "No credential-backed executable model route is available. Configure a credential, then choose a model."

  def message(other), do: "Model selection failed: #{inspect(other)}"

  @spec resolve_with_context(intent(), context()) ::
          {:ok, ModelSelection.t()} | {:error, resolution_error()}
  defp resolve_with_context(%ModelSelection{} = selection, %{opts: opts}),
    do: restore(selection, opts)

  defp resolve_with_context(%Stored{} = stored, %{opts: opts}),
    do: restore(stored, opts)

  defp resolve_with_context(intent, context) when is_map(intent) do
    normalized = string_key_map(intent)

    case Map.get(normalized, "version") do
      version when is_integer(version) ->
        restore(normalized, Keyword.put(context.opts, :backend_spec, context.spec))

      _raw ->
        resolve_raw_intent(normalized, context)
    end
  end

  defp resolve_with_context(nil, context), do: default_selection(context)

  defp resolve_with_context(intent, context) when is_binary(intent) do
    value = String.trim(intent)
    unconfigured_model = Config.unconfigured_model()

    case value do
      "" -> default_selection(context)
      ^unconfigured_model -> default_selection(context)
      "ms2_" <> _rest -> resolve_stable_id(value, context)
      _model -> resolve_raw_intent(%{"model" => value}, context)
    end
  end

  defp resolve_with_context(_intent, _context) do
    {:error,
     {:invalid_model_selection,
      "Model selection must be an exact route id, model id, or versioned selection."}}
  end

  @spec resolve_stable_id(String.t(), context()) ::
          {:ok, ModelSelection.t()} | {:error, resolution_error()}
  defp resolve_stable_id(id, context) do
    candidate_opts =
      context.opts
      |> Keyword.put(:backend_spec, context.spec)
      |> Keyword.put(:config, context.config)
      |> Keyword.put(:credential_snapshot, context.snapshot)

    matches =
      candidate_opts
      |> candidates()
      |> Enum.filter(&(ModelSelection.id(&1.selection) == id))

    case matches do
      [%ModelCandidate{selection: selection}] ->
        with :ok <- credential_available(selection.credential, context.snapshot, context.opts) do
          {:ok, selection}
        end

      [] ->
        correction(
          "The exact saved route is no longer available. Open /model and choose it again."
        )

      _ambiguous ->
        correction("The exact route id is ambiguous. Open /model and choose a route again.")
    end
  end

  @spec restore_stored(Stored.t(), keyword()) ::
          {:ok, ModelSelection.t()} | {:error, resolution_error()}
  defp restore_stored(%Stored{} = stored, opts) do
    snapshot = Keyword.get_lazy(opts, :credential_snapshot, &Credentials.snapshot/0)
    config = Keyword.get(opts, :config, %Config{})

    with {:ok, spec} <- backend_spec(Keyword.put(opts, :backend_id, stored.backend_id)),
         true <- spec.id == stored.backend_id,
         :ok <- credential_available(stored.credential, snapshot, opts),
         :ok <- validate_stored_source(stored, config, snapshot, spec, opts),
         {:ok, selection} <- materialize_stored(stored, spec, snapshot),
         :ok <- validate_backend_capabilities(selection, spec) do
      {:ok, selection}
    else
      {:error, {:selection_correction_required, _message}} = error ->
        error

      {:error, reason} ->
        correction(message(reason))

      false ->
        correction(
          "The saved model selection belongs to a different backend. Choose the exact route again."
        )
    end
  end

  @spec materialize_stored(Stored.t(), Spec.t(), Snapshot.t()) ::
          {:ok, ModelSelection.t()} | {:error, resolution_error()}
  defp materialize_stored(stored, spec, snapshot) do
    credential =
      case stored.credential do
        %OAuth{} -> Snapshot.oauth_ref(snapshot)
        credential -> credential
      end

    case ModelSelection.build(spec, stored.route, credential, stored.policy, stored.evidence) do
      {:ok, selection} ->
        {:ok, selection}

      {:error, reason} ->
        {:error,
         {:route_unavailable,
          "Saved exact route cannot be materialized: #{MingaAgent.Redaction.format_error(reason)}. Choose the route again."}}
    end
  end

  @spec validate_stored_source(Stored.t(), Config.t(), Snapshot.t(), Spec.t(), keyword()) ::
          :ok | {:error, resolution_error()}
  defp validate_stored_source(stored, config, snapshot, spec, opts) do
    {kind, provider, model_id} = stored.route.origin
    context = %{config: config, snapshot: snapshot, spec: spec, opts: opts}

    input = %{
      provider: provider,
      model_id: model_id,
      credential: stored.credential,
      kind: kind
    }

    with {:ok, source} <- stored_source(stored, config, opts),
         {:ok, expected} <- build_route(Map.put(input, :source, source), context),
         true <- expected.execution == stored.route.execution,
         true <- expected.request_provider == stored.route.request_provider,
         true <- expected.id == stored.route.id,
         true <- expected.metadata == stored.route.metadata,
         true <- stored_policy_matches?(stored.policy, source) do
      :ok
    else
      _changed ->
        correction(
          "The saved route no longer matches its source-owned endpoint, authentication, model, or policy. Choose the exact route again."
        )
    end
  end

  @spec stored_source(Stored.t(), Config.t(), keyword()) ::
          {:ok, source()} | {:error, term()}
  defp stored_source(
         %Stored{route: %Route{origin: {_kind, provider, model_id}}, evidence: %{catalog: true}},
         _config,
         opts
       ) do
    case exact_catalog_model(provider, model_id, opts) do
      {:ok, model} -> {:ok, {:catalog, model}}
      error -> error
    end
  end

  defp stored_source(
         %Stored{
           route: %Route{origin: {:custom, provider, model_id}},
           evidence: %{catalog: false}
         },
         config,
         _opts
       ),
       do: custom_model(provider, model_id, config)

  defp stored_source(_stored, _config, _opts), do: {:error, :invalid_source}

  @spec stored_policy_matches?(Policy.t(), source()) :: boolean()
  defp stored_policy_matches?(policy, source) do
    expected_limits = limits(source)

    Map.take(policy.capabilities, [:tools, :images, :tool_result_images, :streaming]) ==
      capabilities(source) and
      policy.reasoning.options == reasoning_options(source) and
      Map.take(policy.limits, [:context, :input, :output]) == expected_limits and
      saved_output_within_limit?(policy.limits.request_output, expected_limits.output)
  end

  @spec saved_output_within_limit?(pos_integer(), pos_integer() | nil) :: boolean()
  defp saved_output_within_limit?(_requested, nil), do: true
  defp saved_output_within_limit?(requested, limit), do: requested <= limit

  @spec default_selection(context()) ::
          {:ok, ModelSelection.t()} | {:error, resolution_error()}
  defp default_selection(context) do
    candidate_opts =
      context.opts
      |> Keyword.put(:backend_spec, context.spec)
      |> Keyword.put(:config, context.config)
      |> Keyword.put(:credential_snapshot, context.snapshot)

    case candidates(candidate_opts) do
      [%ModelCandidate{selection: selection} | _rest] -> {:ok, selection}
      [] -> {:error, :no_available_model}
    end
  end

  @spec resolve_raw_intent(map(), context()) ::
          {:ok, ModelSelection.t()} | {:error, resolution_error()}
  defp resolve_raw_intent(intent, context) do
    requested_model = Map.get(intent, "model")

    if is_binary(requested_model) and requested_model != "" do
      do_resolve_raw_intent(requested_model, intent, context)
    else
      default_selection(context)
    end
  end

  @spec do_resolve_raw_intent(String.t(), map(), context()) ::
          {:ok, ModelSelection.t()} | {:error, resolution_error()}
  defp do_resolve_raw_intent(requested_model, intent, context) do
    exact_model = apply_legacy_provider_hint(requested_model, Map.get(intent, "provider"))

    with {:ok, requested_provider, model_id} <-
           exact_model_identity(exact_model, models(context.opts)),
         source_provider = catalog_provider(requested_provider),
         {:ok, source} <-
           model_source(source_provider, model_id, context.config, context.opts),
         {:ok, route_kind} <- route_kind(source, source_provider, context.config),
         {:ok, credential} <-
           choose_credential(
             requested_provider,
             source_provider,
             route_kind,
             intent,
             context
           ),
         :ok <- credential_available(credential, context.snapshot, context.opts),
         route_input = %{
           source: source,
           provider: source_provider,
           model_id: model_id,
           credential: credential,
           kind: route_kind
         },
         {:ok, route} <- build_route(route_input, context),
         {:ok, policy} <- build_policy(source, intent, context.config),
         evidence = Evidence.new(match?({:catalog, _}, source), route_kind == :custom),
         {:ok, selection} <-
           ModelSelection.build(context.spec, route, credential, policy, evidence),
         :ok <- validate_backend_capabilities(selection, context.spec) do
      {:ok, selection}
    else
      {:error, reason} = error when is_tuple(reason) ->
        error

      {:error, reason} ->
        route_error(
          "The exact route cannot be executed by ReqLLM: #{MingaAgent.Redaction.format_error(reason)}. Check its protocol, limits, and capability declarations."
        )
    end
  end

  @type source :: {:catalog, map()} | {:custom, map()}
  @type route_kind :: :catalog | :custom

  @spec model_source(String.t(), String.t(), Config.t(), keyword()) ::
          {:ok, source()} | {:error, resolution_error()}
  defp model_source(provider, model_id, config, opts) do
    case custom_model(provider, model_id, config) do
      {:ok, source} ->
        {:ok, source}

      {:error, _missing} ->
        case exact_catalog_model(provider, model_id, opts) do
          {:ok, model} -> {:ok, {:catalog, model}}
          {:error, :not_found} -> {:error, {:model_not_found, "#{provider}:#{model_id}"}}
        end
    end
  end

  @spec custom_model(String.t(), String.t(), Config.t()) ::
          {:ok, source()} | {:error, resolution_error()}
  defp custom_model(provider, model_id, config) do
    with endpoint when is_map(endpoint) <- endpoint_config(config, provider),
         models when is_map(models) <- value(endpoint, "models"),
         model when is_map(model) <- map_value_by_string_key(models, model_id) do
      {:ok, {:custom, string_key_map(model)}}
    else
      _missing -> {:error, {:model_not_found, "#{provider}:#{model_id}"}}
    end
  end

  @spec route_kind(source(), String.t(), Config.t()) ::
          {:ok, route_kind()} | {:error, resolution_error()}
  defp route_kind({:custom, _model}, _provider, _config), do: {:ok, :custom}

  defp route_kind({:catalog, _model}, provider, config) do
    if custom_endpoint_override?(config, provider), do: {:ok, :custom}, else: {:ok, :catalog}
  end

  @spec choose_credential(String.t(), String.t(), route_kind(), map(), context()) ::
          {:ok, ModelSelection.credential_ref()} | {:error, resolution_error()}
  defp choose_credential(
         "openai_codex",
         _source_provider,
         _route_kind,
         intent,
         context
       ) do
    choose_from_profiles(oauth_profiles(context.snapshot), intent, "openai_codex")
  end

  defp choose_credential(
         _requested_provider,
         source_provider,
         :custom,
         intent,
         context
       ) do
    with endpoint when is_map(endpoint) <-
           endpoint_auth_config(context.config, source_provider),
         {:ok, configured_mode} <- configured_auth_mode(endpoint),
         :ok <- requested_auth_matches(intent, configured_mode) do
      profiles =
        custom_credential_profiles(source_provider, configured_mode, context.snapshot)

      choose_from_profiles(profiles, intent, source_provider)
    else
      {:error, _reason} = error -> error
      _missing -> route_error("The custom endpoint authentication declaration is missing.")
    end
  end

  defp choose_credential(
         _requested_provider,
         source_provider,
         :catalog,
         intent,
         context
       ) do
    profiles = catalog_credential_profiles(source_provider, context.snapshot)
    choose_from_profiles(profiles, intent, source_provider)
  end

  @spec requested_auth_matches(map(), :api_key | :oauth | :none) ::
          :ok | {:error, resolution_error()}
  defp requested_auth_matches(intent, configured_mode) do
    case normalize_auth_mode(Map.get(intent, "auth_mode")) do
      nil ->
        :ok

      ^configured_mode ->
        :ok

      :invalid ->
        {:error, {:invalid_model_selection, "Unknown auth mode. Use api_key, oauth, or none."}}

      _different ->
        {:error,
         {:invalid_model_selection,
          "The requested auth mode does not match the configured endpoint."}}
    end
  end

  @spec choose_from_profiles([ModelSelection.credential_ref()], map(), String.t()) ::
          {:ok, ModelSelection.credential_ref()} | {:error, resolution_error()}
  defp choose_from_profiles(profiles, intent, provider) do
    requested_id = Map.get(intent, "selection_credential")
    requested_auth = normalize_auth_mode(Map.get(intent, "auth_mode"))

    filtered = filter_profiles(profiles, requested_id, requested_auth)

    case filtered do
      [credential] ->
        {:ok, credential}

      [] when is_binary(requested_id) ->
        {:error, {:credential_unavailable, requested_id}}

      [] ->
        {:error, {:credential_unavailable, "#{provider}:configured-profile"}}

      _ambiguous ->
        {:error,
         {:invalid_model_selection,
          "Model #{inspect(Map.get(intent, "model"))} has multiple credential routes. Choose an exact route from /model."}}
    end
  end

  @spec filter_profiles([ModelSelection.credential_ref()], term(), atom() | :invalid | nil) ::
          [ModelSelection.credential_ref()]
  defp filter_profiles(_profiles, _requested_id, :invalid), do: []

  defp filter_profiles(profiles, requested_id, requested_auth) do
    Enum.filter(profiles, fn credential ->
      (is_nil(requested_id) or ModelSelection.credential_id(credential) == requested_id) and
        (is_nil(requested_auth) or credential_auth_mode(credential) == requested_auth)
    end)
  end

  @spec catalog_credential_profiles(String.t(), Snapshot.t()) :: [ModelSelection.credential_ref()]
  defp catalog_credential_profiles("ollama", _snapshot), do: [None.new("ollama")]

  defp catalog_credential_profiles(provider, snapshot) do
    api_key_profiles(provider, snapshot) ++
      if(provider == "openai", do: oauth_profiles(snapshot), else: [])
  end

  @spec custom_credential_profiles(String.t(), term(), Snapshot.t()) ::
          [ModelSelection.credential_ref()]
  defp custom_credential_profiles(provider, mode, _snapshot) when mode in [:none, "none"] do
    [None.new(provider)]
  end

  defp custom_credential_profiles(provider, mode, snapshot)
       when mode in [:api_key, "api_key", nil] do
    api_key_profiles(provider, snapshot)
  end

  defp custom_credential_profiles(_provider, _invalid_mode, _snapshot), do: []

  @spec api_key_profiles(String.t(), Snapshot.t()) :: [ApiKey.t()]
  defp api_key_profiles(provider, snapshot) do
    case Snapshot.provider_source(snapshot, provider) do
      source when source in [:env, :file] -> [ApiKey.new(provider, source)]
      nil -> []
    end
  end

  @spec oauth_profiles(Snapshot.t()) :: [OAuth.t()]
  defp oauth_profiles(%Snapshot{oauth_ref: %OAuth{} = ref}), do: [ref]
  defp oauth_profiles(%Snapshot{}), do: []

  @spec credential_available(ModelSelection.credential_ref(), Snapshot.t(), keyword()) ::
          :ok | {:error, resolution_error()}
  defp credential_available(%None{}, _snapshot, _opts), do: :ok

  defp credential_available(
         %ApiKey{provider: provider, source: source} = credential,
         snapshot,
         _opts
       ) do
    if Snapshot.provider_source(snapshot, provider) == source do
      :ok
    else
      {:error, {:credential_unavailable, ModelSelection.credential_id(credential)}}
    end
  end

  defp credential_available(%OAuth{} = credential, snapshot, opts),
    do: validate_current_oauth(credential, Snapshot.oauth_ref(snapshot), opts)

  @spec validate_current_oauth(OAuth.t(), OAuth.t() | nil, keyword()) ::
          :ok | {:error, resolution_error()}
  defp validate_current_oauth(credential, %OAuth{} = current, opts) do
    with :ok <- compare_oauth_ref(credential, current) do
      if Keyword.get(opts, :candidate_resolution, false),
        do: :ok,
        else: pin_and_compare_oauth(current, opts)
    end
  end

  defp validate_current_oauth(credential, nil, _opts),
    do: {:error, {:credential_unavailable, ModelSelection.credential_id(credential)}}

  @spec pin_and_compare_oauth(OAuth.t(), keyword()) :: :ok | {:error, resolution_error()}
  defp pin_and_compare_oauth(credential, opts) do
    path = credential.oauth_path || Keyword.get(opts, :oauth_path, Credentials.oauth_path())

    case Credentials.pin_oauth(:openai_codex, path) do
      {:ok, current} ->
        compare_oauth_ref(credential, current)

      {:error, _reason} ->
        {:error, {:credential_unavailable, ModelSelection.credential_id(credential)}}
    end
  end

  @spec compare_oauth_ref(OAuth.t(), OAuth.t()) :: :ok | {:error, resolution_error()}
  defp compare_oauth_ref(expected, current) do
    exact_source? = expected.source_id == current.source_id

    if expected.provider == current.provider and
         expected.provider_key == current.provider_key and
         expected.account_id == current.account_id and exact_source? do
      :ok
    else
      {:error, {:credential_unavailable, ModelSelection.credential_id(expected)}}
    end
  end

  @spec build_route(map(), context()) :: {:ok, Route.t()} | {:error, resolution_error()}
  defp build_route(%{credential: %OAuth{}, kind: :custom}, _context) do
    route_error("OAuth routes cannot be redirected to a custom endpoint.")
  end

  defp build_route(
         %{source: source, provider: provider, model_id: model_id, credential: %OAuth{}},
         _context
       ) do
    case TextExecution.new(%{
           supported: true,
           family: "openai_responses_compatible",
           wire_protocol: "openai_codex_responses",
           transport: "http",
           provider_model_id: provider_model_id(source, model_id),
           base_url: "https://chatgpt.com/backend-api",
           path: "/codex/responses"
         }) do
      {:ok, execution} ->
        route(source, %{
          provider: provider,
          model_id: model_id,
          request_provider: :openai_codex,
          execution: execution,
          kind: :catalog
        })

      {:error, _reason} ->
        route_error("The OpenAI Codex execution route is invalid.")
    end
  end

  defp build_route(
         %{
           source: source,
           provider: provider,
           model_id: model_id,
           credential: credential,
           kind: :custom
         },
         context
       ) do
    endpoint = effective_endpoint_config(context.config, provider, source)

    with endpoint when is_map(endpoint) <- endpoint,
         {:ok, configured_auth} <- configured_auth_mode(endpoint),
         true <- credential_matches_auth?(credential, configured_auth, provider),
         protocol when is_binary(protocol) <-
           configured_protocol(endpoint) || source_protocol(source),
         {:ok, execution, request_provider} <-
           custom_execution(
             provider,
             model_id,
             protocol,
             endpoint,
             provider_model_id(source, model_id)
           ),
         :ok <- validate_route_auth(configured_auth, protocol) do
      route(source, %{
        provider: provider,
        model_id: model_id,
        request_provider: request_provider,
        execution: execution,
        kind: :custom
      })
    else
      {:error, {:route_unavailable, _message}} = error ->
        error

      _invalid ->
        route_error(
          "Custom endpoint configuration must declare a supported protocol, exact HTTP(S) URL, and compatible authentication mode."
        )
    end
  end

  defp build_route(
         %{source: {:catalog, model} = source, provider: provider, model_id: model_id},
         context
       ) do
    with {:ok, execution} <- catalog_execution(model, provider, context),
         {:ok, request_provider} <- catalog_request_provider(provider) do
      route(source, %{
        provider: provider,
        model_id: model_id,
        request_provider: request_provider,
        execution: execution,
        kind: :catalog
      })
    end
  end

  @spec validate_route_auth(:api_key | :none, String.t()) :: :ok | {:error, resolution_error()}
  defp validate_route_auth(:api_key, _protocol), do: :ok

  defp validate_route_auth(:none, protocol) when protocol in ["openai_chat", "openai_responses"],
    do: :ok

  defp validate_route_auth(:none, _protocol),
    do:
      route_error(
        "The selected protocol requires API-key authentication; anonymous authentication is not supported by its request adapter."
      )

  @spec route(source(), map()) :: {:ok, Route.t()} | {:error, resolution_error()}
  defp route(source, route_data) do
    provider = route_data.provider
    model_id = route_data.model_id

    origin =
      case route_data.kind do
        :catalog -> {:catalog, provider, model_id}
        :custom -> {:custom, provider, model_id}
      end

    attrs = %{
      origin: origin,
      request_provider: route_data.request_provider,
      id: route_id(route_data.request_provider, model_id),
      model_provider: provider,
      model_id: model_id,
      display_name: display_name(source, model_id),
      execution: route_data.execution,
      metadata: source_metadata(source)
    }

    case Route.new(attrs) do
      {:ok, route} ->
        {:ok, route}

      {:error, _reason} ->
        route_error(
          "The selected provider, protocol, endpoint, and path do not form a supported ReqLLM route."
        )
    end
  end

  @spec catalog_execution(map(), String.t(), context()) ::
          {:ok, TextExecution.t()} | {:error, resolution_error()}
  defp catalog_execution(model, provider, context) do
    text = model |> value("execution") |> value("text")
    effective_base_url = catalog_base_url(provider, text, model, context)

    attrs = %{
      supported: value(text, "supported"),
      family: value(text, "family"),
      wire_protocol: value(text, "wire_protocol"),
      transport: value(text, "transport") || "http",
      provider_model_id:
        value(text, "provider_model_id") ||
          provider_model_id({:catalog, model}, value(model, "id")),
      base_url: effective_base_url,
      path: value(text, "path")
    }

    case TextExecution.new(attrs) do
      {:ok, execution} ->
        {:ok, execution}

      {:error, _reason} ->
        route_error(
          "The catalog entry has no complete supported text execution contract. Configure an exact custom route or choose another model."
        )
    end
  end

  @spec catalog_base_url(String.t(), term(), map(), context()) :: String.t() | nil
  defp catalog_base_url("ollama", _text, _model, context),
    do: context.snapshot.ollama_host

  defp catalog_base_url(provider, text, model, context) do
    value(text, "base_url") || value(model, "base_url") ||
      provider_endpoint(provider, context.opts)
  end

  @spec custom_execution(String.t(), String.t(), String.t(), map(), String.t()) ::
          {:ok, TextExecution.t(), Route.request_provider()} | {:error, resolution_error()}
  defp custom_execution(endpoint_id, _model_id, protocol, endpoint, provider_model_id) do
    with {:ok, request_provider, family, canonical_path} <- custom_mapping(endpoint_id, protocol),
         configured_path = value(endpoint, "path"),
         true <- is_nil(configured_path) or configured_path == canonical_path,
         base_url when is_binary(base_url) <- endpoint_url(endpoint),
         {:ok, execution} <-
           TextExecution.new(%{
             supported: true,
             family: family,
             wire_protocol: protocol,
             transport: "http",
             provider_model_id: provider_model_id,
             base_url: base_url,
             path: canonical_path
           }) do
      {:ok, execution, request_provider}
    else
      {:error, {:route_unavailable, _message}} = error ->
        error

      _invalid ->
        route_error("The custom endpoint path or URL is incompatible with its selected protocol.")
    end
  end

  @spec custom_mapping(String.t(), String.t()) ::
          {:ok, Route.request_provider(), String.t(), String.t()} | {:error, resolution_error()}
  defp custom_mapping("ollama", "openai_chat"),
    do: {:ok, :ollama, "openai_chat_compatible", "/chat/completions"}

  defp custom_mapping(_endpoint_id, "openai_chat"),
    do: {:ok, :openai, "openai_chat_compatible", "/chat/completions"}

  defp custom_mapping(_endpoint_id, "openai_responses"),
    do: {:ok, :openai, "openai_responses_compatible", "/responses"}

  defp custom_mapping(_endpoint_id, "anthropic_messages"),
    do: {:ok, :anthropic, "anthropic_messages", "/v1/messages"}

  defp custom_mapping(_endpoint_id, "google_generate_content"),
    do: {:ok, :google, "google_generate_content", "/models/{provider_model_id}:generateContent"}

  defp custom_mapping(_endpoint_id, protocol),
    do: route_error("Protocol #{inspect(protocol)} has no installed exact adapter mapping.")

  @spec catalog_request_provider(String.t()) ::
          {:ok, Route.request_provider()} | {:error, resolution_error()}
  defp catalog_request_provider(provider) do
    case Enum.find(@request_providers, &(Atom.to_string(&1) == provider)) do
      nil -> route_error("Provider #{inspect(provider)} has no installed exact ReqLLM adapter.")
      request_provider -> {:ok, request_provider}
    end
  end

  @spec configured_auth_mode(map()) ::
          {:ok, :api_key | :none} | {:error, resolution_error()}
  defp configured_auth_mode(endpoint) do
    case normalize_auth_mode(value(endpoint, "auth_mode")) do
      mode when mode in [:api_key, :none] ->
        {:ok, mode}

      nil ->
        {:ok, :api_key}

      :oauth ->
        route_error(
          "Custom endpoints support api_key or none authentication. OAuth is bound to the catalog OpenAI Codex endpoint and cannot be redirected."
        )

      :invalid ->
        {:error, {:invalid_model_selection, "Custom endpoint auth_mode must be api_key or none."}}
    end
  end

  @spec credential_matches_auth?(ModelSelection.credential_ref(), atom(), String.t()) :: boolean()
  defp credential_matches_auth?(%ApiKey{provider: provider}, :api_key, endpoint_id),
    do: provider == endpoint_id

  defp credential_matches_auth?(%None{provider: provider}, :none, provider), do: true
  defp credential_matches_auth?(_credential, _mode, _endpoint_id), do: false

  @spec build_policy(source(), map(), Config.t()) ::
          {:ok, Policy.t()} | {:error, resolution_error()}
  defp build_policy(source, intent, config) do
    options = reasoning_options(source)

    requested =
      Map.get(intent, "reasoning_effort") || Map.get(intent, "thinking") || List.first(options)

    limits = limits(source)
    capabilities = capabilities(source)

    if requested in options do
      attrs = %{
        reasoning: %{effort: requested, options: options},
        limits: %{
          context: limits.context,
          input: limits.input,
          output: limits.output,
          request_output: request_output_limit(config.max_tokens, limits.output)
        },
        capabilities: capabilities,
        cost: cost(source)
      }

      case Policy.new(attrs) do
        {:ok, policy} ->
          {:ok, policy}

        {:error, _reason} ->
          {:error, {:incompatible_selection, "The selected model has invalid policy metadata."}}
      end
    else
      {:error,
       {:incompatible_selection,
        "Thinking level #{inspect(requested)} is unavailable for this exact model route. Available: #{Enum.join(options, ", ")}."}}
    end
  end

  @spec validate_backend_capabilities(ModelSelection.t(), Spec.t()) ::
          :ok | {:error, resolution_error()}
  defp validate_backend_capabilities(selection, spec) do
    streaming = selection.policy.capabilities.streaming

    case {selection.backend_id == spec.id, streaming} do
      {false, _streaming} ->
        {:error, {:backend_unavailable, selection.backend_id}}

      {true, false} ->
        {:error,
         {:incompatible_selection,
          "#{selection.route.display_name} does not support streaming text responses."}}

      {true, _supported_or_unknown} ->
        :ok
    end
  end

  @spec build_candidates(map()) :: [ModelCandidate.t()]
  defp build_candidates(context) do
    catalog = models(context.opts)

    opts =
      context.opts
      |> Keyword.put(:model_index, catalog_index(catalog))
      |> Keyword.put(:models, catalog)
      |> Keyword.put(:candidate_resolution, true)

    resolution_context = %{
      spec: context.spec,
      config: context.config,
      snapshot: context.snapshot,
      opts: opts
    }

    intents =
      Enum.flat_map(catalog, &catalog_candidate_intents(&1, context.snapshot, context.config)) ++
        custom_candidate_intents(context.config, context.snapshot)

    intents
    |> Enum.reduce([], fn intent, selections ->
      case resolve_raw_intent(intent, resolution_context) do
        {:ok, selection} ->
          [selection | selections]

        {:error, reason} ->
          warn_configured_candidate_failure(intent, reason)
          selections
      end
    end)
    |> Enum.uniq_by(&ModelSelection.id/1)
    |> Enum.map(&ModelCandidate.new(&1, context.favorites, context.current_id))
    |> Enum.sort_by(&candidate_sort_key/1)
  end

  @spec warn_configured_candidate_failure(map(), term()) :: :ok
  defp warn_configured_candidate_failure(%{"configured_custom" => true, "model" => model}, reason) do
    Minga.Log.warning(
      :agent,
      "Configured model #{inspect(model)} is unavailable: #{MingaAgent.Redaction.format_error(reason)}"
    )
  end

  defp warn_configured_candidate_failure(_intent, _reason), do: :ok

  @spec catalog_candidate_intents(map(), Snapshot.t(), Config.t()) :: [map()]
  defp catalog_candidate_intents(model, snapshot, config) do
    if selectable_catalog_model?(model) do
      provider = provider_string(model)
      model_id = canonical_model_id(model)
      route_kind = if(custom_endpoint_override?(config, provider), do: :custom, else: :catalog)
      profiles = candidate_profiles(provider, route_kind, config, snapshot)

      Enum.map(profiles, fn credential ->
        %{
          "model" => "#{provider}:#{model_id}",
          "selection_credential" => ModelSelection.credential_id(credential),
          "auth_mode" => Atom.to_string(credential_auth_mode(credential))
        }
      end)
    else
      []
    end
  end

  @spec candidate_profiles(String.t(), route_kind(), Config.t(), Snapshot.t()) ::
          [ModelSelection.credential_ref()]
  defp candidate_profiles(provider, :catalog, _config, snapshot),
    do: catalog_credential_profiles(provider, snapshot)

  defp candidate_profiles(provider, :custom, config, snapshot) do
    case endpoint_auth_config(config, provider) do
      endpoint when is_map(endpoint) ->
        case configured_auth_mode(endpoint) do
          {:ok, mode} -> custom_credential_profiles(provider, mode, snapshot)
          {:error, _reason} -> []
        end

      _missing ->
        []
    end
  end

  @spec custom_candidate_intents(Config.t(), Snapshot.t()) :: [map()]
  defp custom_candidate_intents(config, snapshot) do
    case config.api_endpoints do
      endpoints when is_map(endpoints) ->
        Enum.flat_map(endpoints, &custom_endpoint_intents(&1, snapshot))

      _none ->
        []
    end
  end

  @spec custom_endpoint_intents({term(), term()}, Snapshot.t()) :: [map()]
  defp custom_endpoint_intents({provider_key, endpoint}, snapshot) when is_map(endpoint) do
    provider = to_string(provider_key)
    models = value(endpoint, "models")

    case {models, configured_auth_mode(endpoint)} do
      {models, {:ok, mode}} when is_map(models) ->
        profiles = custom_credential_profiles(provider, mode, snapshot)

        Enum.flat_map(models, &custom_model_intents(&1, provider, profiles))

      {_models, {:error, reason}} ->
        Minga.Log.warning(
          :agent,
          "Configured model endpoint #{inspect(provider)} is unavailable: #{MingaAgent.Redaction.format_error(reason)}"
        )

        []

      _invalid ->
        []
    end
  end

  defp custom_endpoint_intents(_entry, _snapshot), do: []

  @spec custom_model_intents({term(), term()}, String.t(), [ModelSelection.credential_ref()]) ::
          [map()]
  defp custom_model_intents({model_id, model}, provider, profiles) when is_map(model) do
    Enum.map(profiles, fn credential ->
      %{
        "model" => "#{provider}:#{model_id}",
        "configured_custom" => true,
        "selection_credential" => ModelSelection.credential_id(credential),
        "auth_mode" => Atom.to_string(credential_auth_mode(credential))
      }
    end)
  end

  defp custom_model_intents(_model, _provider, _profiles), do: []

  @spec selectable_catalog_model?(map()) :: boolean()
  defp selectable_catalog_model?(model) do
    value(model, "deprecated") != true and value(model, "retired") != true and
      value(model, "catalog_only") != true and text_output?(value(model, "modalities")) and
      complete_text_execution?(model)
  end

  @spec complete_text_execution?(map()) :: boolean()
  defp complete_text_execution?(model) do
    text = model |> value("execution") |> value("text")

    value(text, "supported") == true and
      value(text, "transport") in [nil, "http"] and
      Enum.all?(~w(family wire_protocol path), fn key ->
        present_string?(value(text, key))
      end) and present_string?(provider_model_id({:catalog, model}, value(model, "id")))
  end

  @spec text_output?(term()) :: boolean()
  defp text_output?(modalities) when is_map(modalities) do
    outputs = value(modalities, "output")
    is_list(outputs) and (:text in outputs or "text" in outputs)
  end

  defp text_output?(_modalities), do: false

  @spec reasoning_options(source()) :: [String.t()]
  defp reasoning_options({:custom, model}) do
    normalize_reasoning_options(value(model, "reasoning_options"), false)
  end

  defp reasoning_options({:catalog, model}) do
    reasoning = model |> value("capabilities") |> value("reasoning")
    effort = value(reasoning, "effort")
    thinking = value(reasoning, "thinking")
    effort_values = if value(effort, "supported") == true, do: value(effort, "values"), else: nil

    thinking_values =
      if value(thinking, "supported") == true, do: value(thinking, "types"), else: nil

    canonical = effort_values || thinking_values
    fallback = model |> value("extra") |> value("reasoning_options")
    disable? = value(thinking, "disable_supported") == true
    normalize_reasoning_options(canonical || fallback, disable?)
  end

  @spec normalize_reasoning_options(term(), boolean()) :: [String.t()]
  defp normalize_reasoning_options(options, disable?) do
    normalized =
      options
      |> List.wrap()
      |> Enum.flat_map(&reasoning_values/1)
      |> Enum.map(&to_string/1)
      |> Enum.filter(&(&1 in @reasoning_efforts))
      |> Enum.uniq()

    case normalized do
      [] ->
        ["off"]

      controls ->
        controls = if disable? and "none" not in controls, do: ["none" | controls], else: controls
        ["default" | controls]
    end
  end

  @spec reasoning_values(term()) :: [String.t() | atom()]
  defp reasoning_values(value) when is_binary(value) or is_atom(value), do: [value]
  defp reasoning_values(value) when is_map(value), do: List.wrap(value(value, "values"))
  defp reasoning_values(_value), do: []

  @spec limits(source()) :: map()
  defp limits({_kind, model}) do
    raw = value(model, "limits") || %{}

    %{
      context: positive(value(raw, "context")),
      input: positive(value(raw, "input")),
      output: positive(value(raw, "output"))
    }
  end

  @spec capabilities(source()) :: %{
          tools: ModelSelection.capability(),
          images: ModelSelection.capability(),
          tool_result_images: ModelSelection.capability(),
          streaming: ModelSelection.capability()
        }
  defp capabilities({:custom, model}) do
    configured = value(model, "capabilities")

    %{
      tools: configured_capability(configured, "tools"),
      images: configured_capability(configured, "images"),
      tool_result_images: configured_capability(configured, "tool_result_images"),
      streaming: configured_capability(configured, "streaming")
    }
  end

  defp capabilities({:catalog, model}) do
    caps = value(model, "capabilities")
    modalities = value(model, "modalities")
    images = image_capability(value(modalities, "input"))

    %{
      tools: nested_capability(value(caps, "tools"), "enabled"),
      images: images,
      tool_result_images: catalog_tool_result_images(model, caps, images),
      streaming: nested_capability(value(caps, "streaming"), "text")
    }
  end

  @spec catalog_tool_result_images(map(), term(), ModelSelection.capability()) ::
          ModelSelection.capability()
  defp catalog_tool_result_images(_model, _caps, images) when images != true, do: false

  defp catalog_tool_result_images(model, caps, true) do
    protocol =
      model
      |> value("execution")
      |> value("text")
      |> value("wire_protocol")

    catalog_tool_result_images_for_protocol(
      protocol,
      configured_capability(caps, "tool_result_images")
    )
  end

  @spec catalog_tool_result_images_for_protocol(String.t() | nil, ModelSelection.capability()) ::
          ModelSelection.capability()
  defp catalog_tool_result_images_for_protocol(protocol, _explicit)
       when protocol in ["anthropic_messages", "openai_responses", "openai_codex_responses"],
       do: true

  defp catalog_tool_result_images_for_protocol("google_generate_content", true), do: true
  defp catalog_tool_result_images_for_protocol("google_generate_content", _explicit), do: false
  defp catalog_tool_result_images_for_protocol("openai_chat", _explicit), do: false
  defp catalog_tool_result_images_for_protocol(_protocol, _explicit), do: :unknown

  @spec configured_capability(term(), String.t()) :: ModelSelection.capability()
  defp configured_capability(configured, key) when is_map(configured),
    do: boolean_or_unknown(value(configured, key))

  defp configured_capability(_configured, _key), do: :unknown

  @spec nested_capability(term(), String.t()) :: ModelSelection.capability()
  defp nested_capability(value, _key) when is_boolean(value), do: value
  defp nested_capability(value, key) when is_map(value), do: boolean_or_unknown(value(value, key))
  defp nested_capability(_value, _key), do: :unknown

  @spec image_capability(term()) :: ModelSelection.capability()
  defp image_capability(inputs) when is_list(inputs), do: :image in inputs or "image" in inputs
  defp image_capability(_inputs), do: :unknown

  @spec boolean_or_unknown(term()) :: ModelSelection.capability()
  defp boolean_or_unknown(value) when is_boolean(value), do: value
  defp boolean_or_unknown(_value), do: :unknown

  @spec source_metadata(source()) :: map()
  defp source_metadata({:custom, model} = source) do
    caps = capabilities(source)

    metadata =
      source_metadata({:catalog, model})
      |> Map.put(
        :capabilities,
        %{
          tools: transport_capability(caps.tools, :enabled),
          streaming: transport_capability(caps.streaming, :text)
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
      )

    case caps.images do
      true -> Map.put(metadata, :modalities, %{input: [:text, :image], output: [:text]})
      false -> Map.put(metadata, :modalities, %{input: [:text], output: [:text]})
      :unknown -> metadata
    end
  end

  defp source_metadata(source) do
    {_kind, model} = source

    %{
      limits: value(model, "limits"),
      modalities: value(model, "modalities"),
      capabilities: value(model, "capabilities"),
      cost: value(model, "cost")
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @spec transport_capability(ModelSelection.capability(), atom()) :: map() | nil
  defp transport_capability(value, key) when is_boolean(value), do: %{key => value}
  defp transport_capability(:unknown, _key), do: nil

  @spec request_output_limit(pos_integer(), pos_integer() | nil) :: pos_integer()
  defp request_output_limit(configured, model_limit) when is_integer(model_limit),
    do: min(configured, model_limit)

  defp request_output_limit(configured, nil), do: configured

  @spec apply_legacy_provider_hint(String.t(), term()) :: String.t()
  defp apply_legacy_provider_hint(model, provider) when is_binary(provider) do
    normalized_provider = String.downcase(provider)

    case split_model_spec(model) do
      :bare ->
        if normalized_provider in @request_provider_names do
          "#{normalized_provider}:#{model}"
        else
          model
        end

      _explicit ->
        model
    end
  end

  defp apply_legacy_provider_hint(model, _provider), do: model

  @spec exact_model_identity(String.t(), [map()]) ::
          {:ok, String.t(), String.t()} | {:error, resolution_error()}
  defp exact_model_identity(model, catalog) do
    case split_model_spec(model) do
      {:ok, provider, id} ->
        {:ok, provider, id}

      :bare ->
        unique_bare_identity(model, catalog)

      :error ->
        {:error,
         {:invalid_model_selection,
          "Model #{inspect(model)} must be provider:model (or model@provider)."}}
    end
  end

  @spec unique_bare_identity(String.t(), [map()]) ::
          {:ok, String.t(), String.t()} | {:error, resolution_error()}
  defp unique_bare_identity(id, catalog) do
    matches = Enum.filter(catalog, &(id in catalog_model_identifiers(&1)))

    case matches do
      [model] ->
        {:ok, provider_string(model), canonical_model_id(model)}

      [] ->
        {:error, {:model_not_found, id}}

      _many ->
        {:error,
         {:invalid_model_selection,
          "Model #{inspect(id)} is ambiguous. Use provider:model to choose an exact route."}}
    end
  end

  @spec split_model_spec(String.t()) :: {:ok, String.t(), String.t()} | :bare | :error
  defp split_model_spec(model) do
    has_at = String.contains?(model, "@")
    has_colon = String.contains?(model, ":")

    case {has_at, has_colon} do
      {true, false} -> split_exact(model, "@", :model_first)
      {false, true} -> split_exact(model, ":", :provider_first)
      {false, false} -> :bare
      {true, true} -> :error
    end
  end

  @spec split_exact(String.t(), String.t(), :model_first | :provider_first) ::
          {:ok, String.t(), String.t()} | :error
  defp split_exact(value, separator, order) do
    case String.split(value, separator, parts: 2) do
      [left, right] when left != "" and right != "" -> split_order(left, right, order)
      _invalid -> :error
    end
  end

  @spec split_order(String.t(), String.t(), :model_first | :provider_first) ::
          {:ok, String.t(), String.t()}
  defp split_order(left, right, :model_first), do: {:ok, String.downcase(right), left}
  defp split_order(left, right, :provider_first), do: {:ok, String.downcase(left), right}

  @spec exact_catalog_model(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found}
  defp exact_catalog_model(provider, model_id, opts) do
    index = Keyword.get_lazy(opts, :model_index, fn -> catalog_index(models(opts)) end)

    case Map.get(index, {provider, model_id}) do
      nil -> {:error, :not_found}
      model -> {:ok, model}
    end
  end

  @spec catalog_index([map()]) :: %{{String.t(), String.t()} => map()}
  defp catalog_index(catalog) do
    Enum.reduce(catalog, %{}, fn model, index ->
      provider = provider_string(model)

      Enum.reduce(catalog_model_identifiers(model), index, fn identifier, entries ->
        Map.put_new(entries, {provider, identifier}, model)
      end)
    end)
  end

  @spec catalog_model_identifiers(map()) :: [String.t()]
  defp catalog_model_identifiers(model) do
    ([canonical_model_id(model), value(model, "model"), value(model, "provider_model_id")] ++
       List.wrap(value(model, "aliases")))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @spec canonical_model_id(map()) :: String.t()
  defp canonical_model_id(model) do
    id = value(model, "id")
    String.replace_prefix(id, provider_string(model) <> "/", "")
  end

  @spec provider_model_id(source(), String.t()) :: String.t()
  defp provider_model_id({_kind, model}, fallback) do
    value(model, "provider_model_id") || value(model, "model") || fallback
  end

  @spec provider_string(map()) :: String.t()
  defp provider_string(model) do
    provider = value(model, "provider") || value(model, "id")

    case provider do
      value when is_atom(value) -> Atom.to_string(value)
      value when is_binary(value) -> String.split(value, "/", parts: 2) |> List.first()
    end
  end

  @spec catalog_provider(String.t()) :: String.t()
  defp catalog_provider("openai_codex"), do: "openai"
  defp catalog_provider(provider), do: provider

  @spec source_protocol(source()) :: String.t() | nil
  defp source_protocol({:catalog, model}),
    do: model |> value("execution") |> value("text") |> value("wire_protocol")

  defp source_protocol({:custom, model}), do: value(model, "protocol")

  @spec display_name(source(), String.t()) :: String.t()
  defp display_name({_kind, model}, fallback), do: value(model, "name") || fallback

  @spec cost(source()) :: map()
  defp cost({_kind, model}) do
    case value(model, "cost") do
      cost when is_map(cost) -> cost
      _missing -> %{}
    end
  end

  @spec route_id(Route.request_provider(), String.t()) :: String.t()
  defp route_id(request_provider, model_id), do: "#{request_provider}/#{model_id}"

  @spec credential_auth_mode(ModelSelection.credential_ref()) :: :api_key | :oauth | :none
  defp credential_auth_mode(%ApiKey{}), do: :api_key
  defp credential_auth_mode(%OAuth{}), do: :oauth
  defp credential_auth_mode(%None{}), do: :none

  @spec normalize_auth_mode(term()) :: :api_key | :oauth | :none | :invalid | nil
  defp normalize_auth_mode(nil), do: nil
  defp normalize_auth_mode(value) when value in [:api_key, "api_key"], do: :api_key
  defp normalize_auth_mode(value) when value in [:oauth, "oauth"], do: :oauth
  defp normalize_auth_mode(value) when value in [:none, "none"], do: :none
  defp normalize_auth_mode(_value), do: :invalid

  @spec backend_spec(keyword()) :: {:ok, Spec.t()} | {:error, resolution_error()}
  defp backend_spec(opts) do
    case Keyword.get(opts, :backend_spec) do
      %Spec{} = spec ->
        {:ok, spec}

      nil ->
        lookup_backend(
          Keyword.get(opts, :registry, ProviderRegistry),
          Keyword.get(opts, :backend_id, "native")
        )
    end
  end

  @spec lookup_backend(GenServer.server(), String.t()) ::
          {:ok, Spec.t()} | {:error, resolution_error()}
  defp lookup_backend(registry, id) do
    case ProviderRegistry.lookup(registry, id) do
      {:ok, %{spec: spec}} -> {:ok, spec}
      {:error, _reason} -> {:error, {:backend_unavailable, id}}
    end
  catch
    :exit, _reason -> {:error, {:backend_unavailable, id}}
  end

  @spec models(keyword()) :: [map()]
  defp models(opts), do: Keyword.get_lazy(opts, :models, &LLMDB.models/0)

  @spec provider_endpoint(String.t(), keyword()) :: String.t() | nil
  defp provider_endpoint(provider, opts) do
    providers = Keyword.get(opts, :providers)

    case providers do
      providers when is_list(providers) ->
        providers
        |> Enum.find(&(provider_string(&1) == provider))
        |> provider_base_url()

      _runtime ->
        case existing_provider_atom(provider) do
          nil -> nil
          provider_atom -> provider_atom |> LLMDB.provider() |> provider_result_base_url()
        end
    end
  end

  @spec provider_result_base_url({:ok, term()} | term()) :: String.t() | nil
  defp provider_result_base_url({:ok, provider}), do: provider_base_url(provider)
  defp provider_result_base_url(_result), do: nil

  @spec provider_base_url(term()) :: String.t() | nil
  defp provider_base_url(nil), do: nil

  defp provider_base_url(provider),
    do: provider |> value("runtime") |> value("base_url") || value(provider, "base_url")

  @spec existing_provider_atom(String.t()) :: atom() | nil
  defp existing_provider_atom(provider),
    do: Enum.find(@request_providers, &(Atom.to_string(&1) == provider))

  @spec endpoint_config(Config.t(), String.t()) :: map() | nil
  defp endpoint_config(config, provider) do
    case config.api_endpoints do
      endpoints when is_map(endpoints) ->
        endpoints |> map_value_by_string_key(provider) |> normalize_endpoint()

      _none ->
        nil
    end
  end

  @spec normalize_endpoint(term()) :: map() | nil
  defp normalize_endpoint(url) when is_binary(url) and url != "",
    do: %{"url" => url, "auth_mode" => "api_key"}

  defp normalize_endpoint(endpoint) when is_map(endpoint), do: endpoint
  defp normalize_endpoint(_invalid), do: nil

  @spec endpoint_auth_config(Config.t(), String.t()) :: map() | nil
  defp endpoint_auth_config(config, provider) do
    case endpoint_config(config, provider) do
      endpoint when is_map(endpoint) -> endpoint
      nil -> synthetic_endpoint_auth(base_url_override(config))
    end
  end

  @spec synthetic_endpoint_auth(String.t() | nil) :: map() | nil
  defp synthetic_endpoint_auth(nil), do: nil
  defp synthetic_endpoint_auth(_url), do: %{"auth_mode" => "api_key"}

  @spec effective_endpoint_config(Config.t(), String.t(), source()) :: map() | nil
  defp effective_endpoint_config(config, provider, source) do
    endpoint = endpoint_config(config, provider)
    override = base_url_override(config)

    case {endpoint, override} do
      {endpoint, override} when is_map(endpoint) and is_binary(override) ->
        Map.put(endpoint, "url", override)

      {endpoint, _override} when is_map(endpoint) ->
        endpoint

      {nil, override} when is_binary(override) ->
        %{
          "url" => override,
          "protocol" => source_protocol(source),
          "auth_mode" => "api_key"
        }

      _missing ->
        nil
    end
  end

  @spec base_url_override(Config.t()) :: String.t() | nil
  defp base_url_override(config) do
    case config.api_base_url_override do
      value when is_binary(value) and value != "" -> value
      _missing_override -> present_string(config.api_base_url)
    end
  end

  @spec present_string(term()) :: String.t() | nil
  defp present_string(value) when is_binary(value) and value != "", do: value
  defp present_string(_value), do: nil

  @spec custom_endpoint_override?(Config.t(), String.t()) :: boolean()
  defp custom_endpoint_override?(config, provider) do
    is_map(endpoint_config(config, provider)) or present_string?(config.api_base_url_override) or
      present_string?(config.api_base_url)
  end

  @spec endpoint_url(map()) :: String.t() | nil
  defp endpoint_url(endpoint), do: value(endpoint, "url") || value(endpoint, "endpoint")

  @spec configured_protocol(map()) :: String.t() | nil
  defp configured_protocol(endpoint), do: value(endpoint, "protocol")

  @spec candidate_sort_key(ModelCandidate.t()) :: tuple()
  defp candidate_sort_key(%ModelCandidate{selection: selection} = candidate) do
    {
      if(candidate.current, do: 0, else: 1),
      if(candidate.favorite, do: 0, else: 1),
      selection.route.model_provider,
      String.downcase(selection.route.display_name),
      selection.route.execution.wire_protocol,
      ModelSelection.credential_id(selection.credential)
    }
  end

  @spec current_selection_id(term()) :: String.t() | nil
  defp current_selection_id(%ModelSelection{} = selection), do: ModelSelection.id(selection)
  defp current_selection_id(value) when is_binary(value), do: value
  defp current_selection_id(_value), do: nil

  @spec value(term(), String.t()) :: term()
  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, result} -> result
      :error -> value_from_atom_key(map, key)
    end
  end

  defp value(_other, _key), do: nil

  @spec value_from_atom_key(map(), String.t()) :: term()
  defp value_from_atom_key(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  @spec map_value_by_string_key(map(), String.t()) :: term()
  defp map_value_by_string_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, result} -> result
      :error -> value_from_atom_key(map, key)
    end
  end

  @spec string_key_map(map()) :: map()
  defp string_key_map(map) do
    Map.new(map, fn {key, nested} ->
      string_key = if is_atom(key), do: Atom.to_string(key), else: key

      value =
        if is_map(nested) and not is_struct(nested), do: string_key_map(nested), else: nested

      {string_key, value}
    end)
  end

  @spec positive(term()) :: pos_integer() | nil
  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  @spec present_string?(term()) :: boolean()
  defp present_string?(value), do: is_binary(value) and value != ""

  @spec route_error(String.t()) :: {:error, resolution_error()}
  defp route_error(message), do: {:error, {:route_unavailable, message}}

  @spec correction(String.t()) :: {:error, resolution_error()}
  defp correction(message), do: {:error, {:selection_correction_required, message}}
end
