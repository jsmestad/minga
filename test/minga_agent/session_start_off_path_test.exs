defmodule MingaAgent.SessionStartOffPathTest do
  @moduledoc """
  Session start work that must stay off every Editor-facing path (#3934 AC 3, 6, 7).
  """

  # Serial: the hook test sets the global `:agent_hooks` option, and the trace
  # tests install global Erlang call-trace patterns.
  use ExUnit.Case, async: false

  alias Minga.Config.Options
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.ModelResolver
  alias MingaAgent.SessionManager

  defmodule BlockingHook do
    @moduledoc false

    @spec run(map()) :: :allow
    def run(_payload) do
      send(:session_start_off_path_test, {:hook_started, self()})

      receive do
        :release -> :allow
      after
        10_000 -> :allow
      end
    end
  end

  describe "session start" do
    setup do
      Process.register(self(), :session_start_off_path_test)
      previous = Options.get(:agent_hooks)

      {:ok, _hooks} =
        Options.set(:agent_hooks, [
          %{event: "SessionStart", module: BlockingHook, function: :run, timeout_ms: 10_000}
        ])

      on_exit(fn -> Options.set(:agent_hooks, previous) end)
      :ok
    end

    test "initial subscribers attach in init and a slow SessionStart hook holds nothing" do
      token = make_ref()

      {:ok, _id, session} =
        SessionManager.start_session(subscribers: [{self(), []}], start_token: token)

      on_exit(fn -> SessionManager.stop_session_by_pid(session) end)

      # The attach acknowledgement is the first event in the session's order.
      assert_receive {:agent_event, ^session, first}, 2_000
      assert first == {:session_start_attached, token}

      assert_receive {:hook_started, hook}, 2_000

      # While the hook is still running, the session answers calls and has
      # already broadcast that its provider is ready.
      assert %MingaAgent.SessionMetadata{} = GenServer.call(session, :metadata, 500)
      assert_receive {:agent_event, ^session, {:connection_changed, %{provider_phase: :running}}}

      send(hook, :release)
    end
  end

  describe "repeated catalog work" do
    test "session model resolution reuses the cached catalog index" do
      _catalog = LLMDB.providers()
      resolve = fn -> ModelResolver.resolve("unknown", resolver_opts()) end
      _warm = resolve.()

      {_result, calls} = trace_local({ModelResolver, :catalog_index, 1}, resolve)
      assert calls == []
    end

    test "hook dispatch reads the hook list without resolving a model" do
      {hooks, calls} = trace_local({ModelResolver, :_, :_}, &AgentConfig.agent_hooks/0)
      assert is_list(hooks)
      assert calls == []
    end
  end

  @spec resolver_opts() :: keyword()
  defp resolver_opts do
    [
      config: %AgentConfig{},
      credential_snapshot: Snapshot.new(%{"openai" => :env}, nil),
      backend_spec: MingaAgent.ProviderResolver.resolve(:native).spec
    ]
  end

  @spec trace_local({module(), atom(), atom() | non_neg_integer()}, (-> result)) ::
          {result, [tuple()]}
        when result: var
  defp trace_local({module, _function, _arity} = pattern, operation) do
    {:module, ^module} = Code.ensure_loaded(module)
    :erlang.trace_pattern(pattern, true, [:local])
    tracer = spawn_link(fn -> collect([]) end)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      result = operation.()
      :erlang.trace(self(), false, [:call])
      ref = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^ref}
      send(tracer, {:take, self()})
      assert_receive {:calls, calls}
      {result, calls}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern(pattern, false, [:local])
      send(tracer, :stop)
    end
  end

  @spec collect([tuple()]) :: :ok
  defp collect(calls) do
    receive do
      {:trace, _pid, :call, call} ->
        collect([call | calls])

      {:take, owner} ->
        send(owner, {:calls, calls})
        collect([])

      :stop ->
        :ok
    end
  end
end
