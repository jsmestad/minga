defmodule MingaAgent.Test.FixtureInferenceRoute do
  @moduledoc """
  Test-only contributed model route.

  `models/1` returns `config[:models]` when given, otherwise one default model.

  `availability/2` reads the opaque route credential, so tests choose readiness without global state: `%{env: %{"FIXTURE_AVAILABILITY" => mode}}` where mode is `"ready"` (the default), `"unavailable"`, `"raise"`, `"hang"`, or `"invalid"`, and `"FIXTURE_ACCOUNT"` names the reported account. A route registered with an id starting with `offline` is always unavailable, for tests that cannot supply a credential.

  `stream/1` plays a script started with `script/3` for the model's id. Each request pops one step and sends `{:fixture_route_request, model_id, request}` to the observer. Steps are `{:events, events}`, which may include invalid events on purpose; `{:block_after, events}`, which emits the events, sends `{:fixture_route_blocked, model_id}`, and then blocks until cancelled; `{:raise_after, events}`, which raises after the events; or `{:error, reason}`. Cancelling a response sends `{:fixture_route_cancelled, model_id}`. Use a unique model id per test so scripts never collide. The fixture uses only Minga-owned route values.
  """

  @behaviour MingaAgent.InferenceRoute

  alias MingaAgent.InferenceRoute.{Model, Request, Response}

  @remedy "Not signed in. Run: fixture auth login"

  @typedoc "One scripted response."
  @type step ::
          {:events, [term()]}
          | {:block_after, [term()]}
          | {:raise_after, [term()]}
          | {:error, term()}

  @doc "Returns the remedy reported while the fixture is unavailable."
  @spec remedy() :: String.t()
  def remedy, do: @remedy

  @doc "Returns the default model declaration, with optional field overrides."
  @spec model(keyword()) :: Model.t()
  def model(overrides \\ []) do
    {:ok, model} =
      [
        id: "fixture-model",
        display_name: "Fixture Model",
        context_window: 200_000,
        max_output: 32_000,
        reasoning_levels: ["off", "low", "high"],
        tools?: true,
        images_in?: true,
        tool_result_images?: false,
        compaction: :native,
        usage: :tokens,
        cost: :subscription
      ]
      |> Keyword.merge(overrides)
      |> Model.new()

    model
  end

  @doc "Starts a linked script of responses for one model id; requests are reported to `observer`."
  @spec script(String.t(), [step()], pid()) :: {:ok, pid()}
  def script(model_id, steps, observer \\ self()) do
    Agent.start_link(fn -> {steps, observer} end, name: script_name(model_id))
  end

  @impl true
  @spec models(keyword()) :: [Model.t()]
  def models(config), do: Keyword.get_lazy(config, :models, fn -> [model()] end)

  @impl true
  @spec availability(String.t(), MingaAgent.InferenceRoute.route_credential()) ::
          MingaAgent.InferenceRoute.availability()
  def availability("offline" <> _rest, _credential),
    do: {:unavailable, :not_signed_in, @remedy}

  def availability(_route_id, credential) do
    env = credential_env(credential)

    case Map.get(env, "FIXTURE_AVAILABILITY", "ready") do
      "ready" -> {:ready, Map.get(env, "FIXTURE_ACCOUNT", "fixture@example.com")}
      "unavailable" -> {:unavailable, :not_signed_in, @remedy}
      "raise" -> raise "fixture availability failed"
      "hang" -> receive(do: (:never -> {:ready, "never"}))
      "invalid" -> :ready
    end
  end

  @impl true
  @spec stream(Request.t()) :: {:ok, Response.t()} | {:error, term()}
  def stream(%Request{model: %Model{id: model_id}} = request) do
    case GenServer.whereis(script_name(model_id)) do
      nil -> {:error, :fixture_stream_not_configured}
      script -> script |> next_step(model_id, request) |> respond(model_id)
    end
  end

  @impl true
  @spec classify_error(term()) :: {MingaAgent.Event.Error.kind(), String.t()}
  def classify_error(:rate_limited), do: {:rate_limited, "Fixture route is rate limited."}
  def classify_error(_reason), do: {:provider_error, "The fixture route failed."}

  @spec next_step(pid(), String.t(), Request.t()) :: {step() | :exhausted, pid()}
  defp next_step(script, model_id, request) do
    Agent.get_and_update(script, fn
      {[step | rest], observer} ->
        send(observer, {:fixture_route_request, model_id, request})
        {{step, observer}, {rest, observer}}

      {[], observer} ->
        {{:exhausted, observer}, {[], observer}}
    end)
  end

  @spec respond({step() | :exhausted, pid()}, String.t()) ::
          {:ok, Response.t()} | {:error, term()}
  defp respond({{:events, events}, observer}, model_id) do
    cancel = fn ->
      send(observer, {:fixture_route_cancelled, model_id})
      :ok
    end

    {:ok, %Response{events: Stream.map(events, & &1), cancel: cancel}}
  end

  defp respond({{:block_after, events}, observer}, model_id) do
    blocking =
      Stream.resource(
        fn -> :blocking end,
        fn :blocking ->
          send(observer, {:fixture_route_blocked, model_id})

          receive do
            :fixture_route_never -> {:halt, :blocking}
          end
        end,
        fn _state -> :ok end
      )

    respond({{:events, Stream.concat(events, blocking)}, observer}, model_id)
  end

  defp respond({{:raise_after, events}, observer}, model_id) do
    failing = Stream.map([:boom], fn :boom -> raise "fixture events failed" end)
    respond({{:events, Stream.concat(events, failing)}, observer}, model_id)
  end

  defp respond({{:error, reason}, _observer}, _model_id), do: {:error, reason}
  defp respond({:exhausted, _observer}, _model_id), do: {:error, :fixture_script_exhausted}

  @spec script_name(String.t()) :: atom()
  defp script_name(model_id), do: :"fixture_inference_route_script_#{model_id}"

  @spec credential_env(MingaAgent.InferenceRoute.route_credential()) :: map()
  defp credential_env(%{env: env}) when is_map(env), do: env
  defp credential_env(nil), do: %{}
end
