defmodule MingaAgent.InferenceRouteRegistry do
  @moduledoc """
  Source-owned registry for contributed model routes.

  The registry owns registered route declarations, their offered models, and each route's last known `Status`. A source may replace its own routes, but a route id another source owns is rejected and the first route keeps working. When a source stops, `ContributionCleanup` drops its routes through the `:inference_routes` family.

  Route callbacks never run inside the registry process. `register/3` lists models in the caller, and `refresh_availability/2` checks availability and lists models again in bounded worker processes spawned by the caller, so the Editor must never call it. Every change to a route's status publishes `:inference_route_status_changed` on `Minga.Events`. A privately named registry publishes only to the event registry passed as `:events`, so tests never touch the global bus.
  """

  use GenServer

  alias MingaAgent.InferenceRoute
  alias MingaAgent.Event
  alias MingaAgent.InferenceRoute.{Model, PlanWindow, Reporter, Spec, Status}
  alias MingaAgent.InferenceRoute.StatusChangedEvent
  alias MingaAgent.InferenceRouteRegistry.Entry

  @default_availability_timeout 5_000

  @error_kinds [
    :auth_failed,
    :rate_limited,
    :unreachable,
    :invalid_model,
    :context_transition_required,
    :request_admission_refused,
    :provider_error,
    :tool_error,
    :internal_error,
    :unknown
  ]

  @typedoc "Inference route registry server."
  @type server :: GenServer.server()

  @typedoc "Registration failure reason."
  @type register_error ::
          {:duplicate_route_id, String.t(), existing_source :: Spec.source(),
           attempted_source :: Spec.source()}
          | {:invalid_spec, Spec.error()}
          | {:invalid_route_module, module()}
          | {:invalid_models, term()}

  @typedoc "Status report failure reason."
  @type report_error ::
          :unknown_route | :stale_reporter | :invalid_status | PlanWindow.error()

  @type state :: %{
          routes: %{String.t() => Entry.t()},
          reporters: %{String.t() => Reporter.t()},
          events: Minga.Events.registry() | nil
        }

  @doc "Starts the inference route registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    events = Keyword.get_lazy(opts, :events, fn -> default_events(name) end)
    GenServer.start_link(__MODULE__, [name: name, events: events], name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Registers or replaces a route declaration.

  The route module's `models/1` callback runs in the calling process with `opts[:config]` (default `[]`). A replaced route starts again with an unknown status and a new reporter, so the previous reporter becomes stale.
  """
  @spec register(server(), Spec.t() | map() | keyword(), keyword()) ::
          {:ok, Reporter.t()} | {:error, register_error()}
  def register(server, spec_or_attrs, opts \\ [])

  def register(server, %Spec{} = spec, opts) do
    config = Keyword.get(opts, :config, [])

    with :ok <- validate_module(spec.module),
         {:ok, models} <- list_models(spec.module, config) do
      GenServer.call(server, {:register, spec, models, config})
    end
  end

  def register(server, attrs, opts) when is_map(attrs) or is_list(attrs) do
    case Spec.new(attrs) do
      {:ok, spec} -> register(server, spec, opts)
      {:error, reason} -> {:error, {:invalid_spec, reason}}
    end
  end

  @doc "Looks up a registered route by id."
  @spec lookup(server(), String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def lookup(server, id) when is_binary(id), do: GenServer.call(server, {:lookup, id})

  @doc "Lists registered routes sorted by id."
  @spec list(server()) :: [Entry.t()]
  def list(server), do: GenServer.call(server, :list)

  @doc "Records availability reported through the route's current reporter, from any process."
  @spec report_status(server(), Reporter.t(), term()) :: :ok | {:error, report_error()}
  def report_status(server, %Reporter{} = reporter, availability) do
    case Status.new(availability) do
      {:ok, status} -> GenServer.call(server, {:report_status, reporter, status})
      {:error, :invalid_status} -> {:error, :invalid_status}
    end
  end

  @doc """
  Records plan limit windows reported through the route's current reporter, from any process.

  An empty list or nil means the route has no usage data, and Minga shows nothing. Availability is unchanged.
  """
  @spec report_usage(server(), Reporter.t(), [PlanWindow.t() | map() | keyword()] | nil) ::
          :ok | {:error, report_error()}
  def report_usage(server, %Reporter{} = reporter, windows) do
    case PlanWindow.new_list(windows) do
      {:ok, windows} -> GenServer.call(server, {:report_usage, reporter, windows})
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Maps a route failure to a Minga error kind and one actionable sentence.

  The route's `classify_error/1` runs in the calling process. A missing route, a raising callback, or an invalid return falls back to a generic provider error that names the route.
  """
  @spec classify_error(server(), String.t(), term()) :: {Event.Error.kind(), String.t()}
  def classify_error(server, route_id, reason) when is_binary(route_id) do
    case lookup(server, route_id) do
      {:ok, %Entry{spec: spec}} -> route_classification(spec, reason)
      {:error, :not_found} -> {:unreachable, unregistered_message(route_id)}
    end
  catch
    :exit, _reason -> {:unreachable, unregistered_message(route_id)}
  end

  @doc "Formats when a plan window resets in this machine's local time, such as `3:40 PM`."
  @spec reset_label(PlanWindow.t()) :: String.t() | nil
  def reset_label(%PlanWindow{} = window),
    do: PlanWindow.reset_label(window, DateTime.utc_now(), &local_time/1)

  @doc "Converts a UTC time to this machine's local calendar time, the clock `PlanWindow.reset_label/3` formats."
  @spec local_time(DateTime.t()) :: :calendar.datetime()
  def local_time(%DateTime{} = at) do
    at
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
  end

  @doc "Returns the sentence shown when no extension provides a route."
  @spec unregistered_message(String.t()) :: String.t()
  def unregistered_message(route_id) when is_binary(route_id) do
    "The #{route_id} model route is unavailable because no extension provides it. Enable the extension that provides it, or choose another model in /model."
  end

  @doc "Removes every route contributed by a source."
  @spec unregister_source(Spec.source()) :: :ok
  @spec unregister_source(server(), Spec.source()) :: :ok
  def unregister_source(source), do: unregister_source(__MODULE__, source)

  def unregister_source(server, source) do
    GenServer.call(server, {:unregister_source, source})
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Checks every registered route's availability in the calling process and records the results.

  Each route is checked in its own monitored process: it calls `availability/2` under `:timeout` (default 5000 ms), and then `models/1` with the registration config under its own `:models_timeout` (default `:timeout`), so a route can offer new models after the user installs or signs in to its tool. A route whose availability check raises, exits, returns an invalid value, or misses its deadline is recorded as unavailable, with diagnostics in `*Messages*`. A model listing that fails, is invalid, or misses its deadline keeps the previous models and never changes availability. A result is discarded when the route was registered again meanwhile, and its availability is skipped when a newer report arrived during the check. `:route_ids` limits the check to those routes. `:route_credential_fn` receives a route id and returns `{:ok, credential}` for the opaque credential passed to the route, or `{:error, remedy}` to mark the route unavailable without calling it (default: `{:ok, nil}`).
  """
  @spec refresh_availability(server(), keyword()) :: [Entry.t()]
  def refresh_availability(server, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_availability_timeout)
    models_timeout = Keyword.get(opts, :models_timeout, timeout)
    credential_fn = Keyword.get(opts, :route_credential_fn, fn _route_id -> {:ok, nil} end)
    deadline = System.monotonic_time(:millisecond) + timeout

    # Start every check before awaiting any, so all routes share one deadline per phase.
    checks =
      server
      |> list()
      |> only_routes(Keyword.get(opts, :route_ids))
      |> Enum.map(&start_check(&1, credential_fn))

    # Availability is recorded on its own result before any model listing is awaited.
    checked = Enum.map(checks, &await_availability(&1, deadline))
    models_deadline = System.monotonic_time(:millisecond) + models_timeout

    checked
    |> Enum.map(&await_models(&1, models_deadline))
    |> Enum.each(fn {entry, status, models} ->
      GenServer.call(
        server,
        {:refreshed, entry.spec.id, entry.registration, entry.availability_version, status,
         models}
      )
    end)

    list(server)
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    maybe_register_cleanup_callback(Keyword.get(opts, :name, __MODULE__))
    {:ok, %{routes: %{}, reporters: %{}, events: Keyword.fetch!(opts, :events)}}
  end

  @impl true
  def handle_call({:register, %Spec{} = spec, models, config}, _from, state) do
    case Map.fetch(state.routes, spec.id) do
      {:ok, %Entry{spec: %Spec{source: source}}} when source != spec.source ->
        {:reply, {:error, {:duplicate_route_id, spec.id, source, spec.source}}, state}

      _new_or_same_source ->
        reporter = Reporter.issue(spec.id)

        state = %{
          state
          | routes: Map.put(state.routes, spec.id, Entry.new(spec, models, config)),
            reporters: Map.put(state.reporters, spec.id, reporter)
        }

        {:reply, {:ok, reporter}, state}
    end
  end

  def handle_call({:lookup, id}, _from, state) do
    reply =
      case Map.fetch(state.routes, id) do
        {:ok, entry} -> {:ok, entry}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, state.routes |> Map.values() |> Enum.sort_by(& &1.spec.id), state}
  end

  def handle_call(
        {:report_status, %Reporter{route_id: route_id} = reporter, status},
        _from,
        state
      ) do
    case {Map.fetch(state.routes, route_id), Map.fetch(state.reporters, route_id)} do
      {{:ok, entry}, {:ok, ^reporter}} ->
        entry = Entry.availability_updated(entry)
        {:reply, :ok, put_status(state, entry, Status.with_availability(entry.status, status))}

      {{:ok, _entry}, _other_registration} ->
        {:reply, {:error, :stale_reporter}, state}

      {:error, _no_reporter} ->
        {:reply, {:error, :unknown_route}, state}
    end
  end

  def handle_call(
        {:report_usage, %Reporter{route_id: route_id} = reporter, windows},
        _from,
        state
      ) do
    case {Map.fetch(state.routes, route_id), Map.fetch(state.reporters, route_id)} do
      {{:ok, entry}, {:ok, ^reporter}} ->
        {:reply, :ok, put_status(state, entry, Status.with_plan_usage(entry.status, windows))}

      {{:ok, _entry}, _other_registration} ->
        {:reply, {:error, :stale_reporter}, state}

      {:error, _no_reporter} ->
        {:reply, {:error, :unknown_route}, state}
    end
  end

  # A refresh result applies only to the registration it checked, and only if no newer availability arrived.
  def handle_call({:refreshed, id, registration, version, status, models}, _from, state) do
    case Map.fetch(state.routes, id) do
      {:ok, %Entry{registration: ^registration, availability_version: ^version} = entry} ->
        entry = entry |> refreshed_models(models) |> Entry.availability_updated()
        {:reply, :ok, put_status(state, entry, Status.with_availability(entry.status, status))}

      {:ok, %Entry{registration: ^registration} = entry} ->
        {:reply, :ok, put_route(state, refreshed_models(entry, models))}

      _replaced_or_removed ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:unregister_source, source}, _from, state) do
    removed =
      for {id, %Entry{spec: %Spec{source: ^source}}} <- state.routes, do: id

    {:reply, :ok,
     %{
       state
       | routes: Map.drop(state.routes, removed),
         reporters: Map.drop(state.reporters, removed)
     }}
  end

  # Publishes only real changes, so chrome re-renders when what it shows changed.
  @spec put_status(state(), Entry.t(), Status.t()) :: state()
  defp put_status(state, %Entry{status: status} = entry, status), do: put_route(state, entry)

  defp put_status(state, %Entry{spec: spec} = entry, status) do
    publish_status(state.events, %StatusChangedEvent{
      route_id: spec.id,
      short_name: Spec.short_name(spec),
      status: status
    })

    put_route(state, Entry.with_status(entry, status))
  end

  @spec publish_status(Minga.Events.registry() | nil, StatusChangedEvent.t()) :: :ok
  defp publish_status(nil, _event), do: :ok

  defp publish_status(events, event),
    do: Minga.Events.broadcast(:inference_route_status_changed, event, events)

  @spec default_events(server()) :: Minga.Events.registry() | nil
  defp default_events(__MODULE__), do: Minga.Events.default_registry()
  defp default_events(_private_name), do: nil

  @spec refreshed_models(Entry.t(), {:ok, [Model.t()]} | {:error, term()}) :: Entry.t()
  defp refreshed_models(entry, {:ok, models}), do: Entry.with_models(entry, models)
  defp refreshed_models(entry, {:error, _kept}), do: entry

  @spec only_routes([Entry.t()], [String.t()] | nil) :: [Entry.t()]
  defp only_routes(entries, nil), do: entries
  defp only_routes(entries, ids) when is_list(ids), do: Enum.filter(entries, &(&1.spec.id in ids))

  @spec put_route(state(), Entry.t()) :: state()
  defp put_route(state, %Entry{spec: spec} = entry),
    do: %{state | routes: Map.put(state.routes, spec.id, entry)}

  @spec route_classification(Spec.t(), term()) :: {Event.Error.kind(), String.t()}
  defp route_classification(spec, reason) do
    case spec.module.classify_error(reason) do
      {kind, message} when is_atom(kind) and is_binary(message) and message != "" ->
        {known_kind(kind), message}

      other ->
        classification_failed(spec, {:invalid_return, other})
    end
  rescue
    exception -> classification_failed(spec, {:exception, Exception.message(exception)})
  end

  @spec known_kind(atom()) :: Event.Error.kind()
  defp known_kind(kind) when kind in @error_kinds, do: kind
  defp known_kind(_kind), do: :provider_error

  @spec classification_failed(Spec.t(), term()) :: {Event.Error.kind(), String.t()}
  defp classification_failed(spec, failure) do
    Minga.Log.warning(
      :agent,
      "Model route #{spec.id} could not classify an error: #{MingaAgent.Redaction.format_error(failure)}"
    )

    {:provider_error,
     "#{spec.display_name} could not complete this request. Open *Messages* for details."}
  end

  @spec maybe_register_cleanup_callback(server()) :: :ok
  defp maybe_register_cleanup_callback(__MODULE__) do
    Minga.Extension.ContributionCleanup.register(
      :inference_routes,
      &__MODULE__.unregister_source/1
    )
  end

  defp maybe_register_cleanup_callback(_name), do: :ok

  @spec validate_module(module()) :: :ok | {:error, {:invalid_route_module, module()}}
  defp validate_module(module) do
    exported? =
      Code.ensure_loaded?(module) and
        Enum.all?(InferenceRoute.callbacks(), fn {fun, arity} ->
          function_exported?(module, fun, arity)
        end)

    if exported?, do: :ok, else: {:error, {:invalid_route_module, module}}
  end

  @spec list_models(module(), keyword()) ::
          {:ok, [Model.t()]} | {:error, {:invalid_models, term()}}
  defp list_models(module, config) do
    case module.models(config) do
      [_first | _rest] = models -> validate_models(models)
      other -> {:error, {:invalid_models, {:expected_non_empty_list, other}}}
    end
  rescue
    exception -> {:error, {:invalid_models, {:exception, Exception.message(exception)}}}
  end

  @spec validate_models([term()]) :: {:ok, [Model.t()]} | {:error, {:invalid_models, term()}}
  defp validate_models(models) do
    validated =
      Enum.reduce_while(models, {:ok, []}, fn model, {:ok, acc} ->
        case Model.validate(model) do
          {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
          {:error, reason} -> {:halt, {:error, {:invalid_models, reason}}}
        end
      end)

    with {:ok, reversed} <- validated do
      valid = Enum.reverse(reversed)

      if length(Enum.uniq_by(valid, & &1.id)) == length(valid),
        do: {:ok, valid},
        else: {:error, {:invalid_models, :duplicate_model_id}}
    end
  end

  @typep check :: {Entry.t(), pid(), reference(), reference()}
  @typep models_result :: {:ok, [Model.t()]} | {:error, term()}

  @typep credential_fn ::
           (String.t() -> {:ok, InferenceRoute.route_credential()} | {:error, String.t()})

  # The worker reports availability first, then lists models, so the two never share a fate.
  @spec start_check(Entry.t(), credential_fn()) :: check()
  defp start_check(%Entry{spec: spec} = entry, credential_fn) do
    parent = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        availability =
          try do
            check_with_credential(spec, credential_fn.(spec.id))
          rescue
            exception -> {:raised, Exception.message(exception)}
          end

        send(parent, {tag, :availability, availability})

        models =
          try do
            list_models(spec.module, entry.config)
          rescue
            exception -> {:error, {:exception, Exception.message(exception)}}
          end

        send(parent, {tag, :models, models})
      end)

    {entry, pid, monitor, tag}
  end

  @spec check_with_credential(Spec.t(), term()) :: {:returned, term()}
  defp check_with_credential(spec, {:ok, credential}),
    do: {:returned, spec.module.availability(spec.id, credential)}

  defp check_with_credential(_spec, {:error, remedy}) when is_binary(remedy),
    do: {:returned, {:unavailable, :invalid_route_credential, remedy}}

  @spec await_availability(check(), integer()) :: {check(), Status.t(), :listing | :stopped}
  defp await_availability({%Entry{spec: spec}, pid, monitor, tag} = check, deadline) do
    receive do
      {^tag, :availability, result} ->
        {check, check_status(spec, result), :listing}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {check, check_status(spec, {:exited, reason}), :stopped}
    after
      remaining(deadline) ->
        stop_check(check)
        {check, check_status(spec, :timeout), :stopped}
    end
  end

  @spec await_models({check(), Status.t(), :listing | :stopped}, integer()) ::
          {Entry.t(), Status.t(), models_result()}
  defp await_models({{entry, _pid, _monitor, _tag}, status, :stopped}, _deadline),
    do: {entry, status, {:error, :not_listed}}

  defp await_models({{entry, pid, monitor, tag} = check, status, :listing}, deadline) do
    receive do
      {^tag, :models, result} ->
        Process.demonitor(monitor, [:flush])
        {entry, status, refreshed_model_list(entry.spec, result)}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {entry, status, refreshed_model_list(entry.spec, {:error, {:exited, reason}})}
    after
      remaining(deadline) ->
        stop_check(check)
        {entry, status, refreshed_model_list(entry.spec, {:error, :timeout})}
    end
  end

  @spec remaining(integer()) :: non_neg_integer()
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @spec stop_check(check()) :: :ok
  defp stop_check({_entry, pid, monitor, tag}) do
    Process.exit(pid, :kill)
    Process.demonitor(monitor, [:flush])

    receive do
      {^tag, _phase, _late} -> :ok
    after
      0 -> :ok
    end

    receive do
      {^tag, _phase, _late} -> :ok
    after
      0 -> :ok
    end
  end

  @spec refreshed_model_list(Spec.t(), term()) :: {:ok, [Model.t()]} | {:error, term()}
  defp refreshed_model_list(_spec, {:ok, models}), do: {:ok, models}
  defp refreshed_model_list(_spec, {:error, :not_listed} = kept), do: kept

  defp refreshed_model_list(spec, {:error, reason} = kept) do
    Minga.Log.warning(
      :agent,
      "Model route #{spec.id} returned an invalid model list; keeping its previous models: #{MingaAgent.Redaction.format_error(reason)}"
    )

    kept
  end

  @spec check_status(Spec.t(), term()) :: Status.t()
  defp check_status(spec, {:returned, availability}) do
    case Status.new(availability) do
      {:ok, %Status{availability: :unknown}} -> failed_status(spec, {:invalid_return, :unknown})
      {:ok, status} -> status
      {:error, :invalid_status} -> failed_status(spec, {:invalid_return, availability})
    end
  end

  defp check_status(spec, failure), do: failed_status(spec, failure)

  @spec failed_status(Spec.t(), term()) :: Status.t()
  defp failed_status(spec, failure) do
    Minga.Log.warning(
      :agent,
      "Model route #{spec.id} availability check failed: #{MingaAgent.Redaction.format_error(failure)}"
    )

    {:ok, status} =
      Status.new(
        {:unavailable, :availability_check_failed,
         "Could not check #{spec.display_name}. Reopen /model to retry, or open *Messages* for details."}
      )

    status
  end
end
