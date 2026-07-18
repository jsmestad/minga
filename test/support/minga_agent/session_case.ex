defmodule Minga.Test.SessionCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Minga.Test.SessionCase

      alias Minga.Extension.CodeLease
      alias MingaAgent.Branch
      alias MingaAgent.Event
      alias MingaAgent.MCP.FakeTransport
      alias MingaAgent.MCP.ServerConfig
      alias MingaAgent.ProviderRegistry
      alias MingaAgent.Providers.Native
      alias MingaAgent.Session
      alias MingaAgent.SessionStore

      @event_timeout 5_000
    end
  end

  @spec await_turn_complete() :: :ok
  def await_turn_complete do
    ExUnit.Assertions.assert_receive(
      {:agent_event, _, {:status_changed, :idle}},
      5_000
    )

    :ok
  end

  @spec send_provider_event(GenServer.server(), MingaAgent.Event.t()) :: :ok
  def send_provider_event(session, event) do
    send(session, {:agent_provider_event, event})
    MingaAgent.Session.status(session)
    :ok
  end

  @spec idle_gc_token_fn([reference()]) :: (-> reference())
  def idle_gc_token_fn(tokens) do
    token_source = start_supervised!({Agent, fn -> tokens end})

    fn ->
      Agent.get_and_update(token_source, fn
        [token | rest] -> {token, rest}
        [] -> raise "idle_gc_token_fn called more times than expected"
      end)
    end
  end

  @spec start_test_session(keyword()) :: pid()
  def start_test_session(opts) do
    opts = Keyword.put_new(opts, :persist?, false)
    child_id = {:session, System.unique_integer([:positive, :monotonic])}
    start_supervised!({MingaAgent.Session, opts}, id: child_id)
  end

  @spec start_subscribed_session(module(), keyword()) :: pid()
  def start_subscribed_session(provider \\ Minga.Test.SessionMockProvider, provider_opts \\ []) do
    provider_opts = native_provider_opts(provider, provider_opts)
    session = start_test_session(provider: provider, provider_opts: provider_opts)
    MingaAgent.Session.subscribe(session)
    session
  end

  @spec agent_config(keyword()) :: MingaAgent.Config.t()
  def agent_config(fields), do: struct!(MingaAgent.Config, fields)

  @spec build_stream_response(Enumerable.t(), map()) :: {:ok, ReqLLM.StreamResponse.t()}
  def build_stream_response(chunks, usage \\ %{}) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{usage: usage, finish_reason: :stop}
      end)

    {:ok,
     %ReqLLM.StreamResponse{
       stream: chunks,
       metadata_handle: handle,
       cancel: fn -> :ok end,
       model: elem(ReqLLM.model("anthropic:claude-sonnet-4-20250514"), 1),
       context: ReqLLM.Context.new()
     }}
  end

  @spec send_approval(GenServer.server(), pid()) :: :ok
  def send_approval(session, reply_to \\ self()) do
    :ok = MingaAgent.Session.continue(session)

    approval = %MingaAgent.Event.ToolApproval{
      tool_call_id: "tc1",
      name: "shell",
      args: %{"command" => "rm -rf /"},
      reply_to: reply_to
    }

    send_provider_event(session, approval)
    ExUnit.Assertions.assert_receive({:agent_event, _, {:approval_pending, _}}, 5_000)
    :ok
  end

  @spec start_slow_turn(String.t()) :: pid()
  def start_slow_turn(prompt \\ "first") do
    session = start_subscribed_session(Minga.Test.SessionSlowMockProvider)
    ExUnit.Assertions.assert(is_pid(MingaAgent.Session.get_provider(session)))
    ExUnit.Assertions.assert(:ok = MingaAgent.Session.send_prompt(session, prompt))

    ExUnit.Assertions.assert_receive(
      {:agent_event, ^session, {:status_changed, :thinking}},
      5_000
    )

    ExUnit.Assertions.assert_receive({:agent_event, ^session, {:text_delta, ^prompt}}, 5_000)
    session
  end

  @spec finish_slow_turn(GenServer.server()) :: :ok
  def finish_slow_turn(session) do
    Minga.Test.SessionSlowMockProvider.proceed(MingaAgent.Session.get_provider(session))
    ExUnit.Assertions.assert_receive({:agent_event, _, {:status_changed, :idle}}, 5_000)
    :ok
  end

  @spec mcp_session_builtin_tool() :: ReqLLM.Tool.t()
  def mcp_session_builtin_tool do
    ReqLLM.Tool.new!(
      name: "builtin_echo",
      description: "Builtin echo",
      parameter_schema: %{"type" => "object", "properties" => %{}},
      callback: fn _args -> {:ok, "builtin ok"} end
    )
  end

  @spec mcp_session_stream(Enumerable.t()) :: {:ok, ReqLLM.StreamResponse.t()}
  def mcp_session_stream(chunks) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{usage: %{}, finish_reason: :stop}
      end)

    {:ok,
     %ReqLLM.StreamResponse{
       stream: chunks,
       metadata_handle: handle,
       cancel: fn -> :ok end,
       model: elem(ReqLLM.model("anthropic:claude-sonnet-4-20250514"), 1),
       context: ReqLLM.Context.new()
     }}
  end

  @spec idle_process() :: pid()
  def idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  @spec wait_until_subscriber_role(
          GenServer.server(),
          pid(),
          MingaAgent.Session.attachment_role() | nil,
          non_neg_integer()
        ) :: :ok
  def wait_until_subscriber_role(session, pid, expected_role, attempts \\ 20)

  def wait_until_subscriber_role(session, pid, expected_role, attempts) when attempts > 0 do
    case MingaAgent.Session.subscriber_role(session, pid) do
      ^expected_role ->
        :ok

      _other ->
        :sys.get_state(session)
        wait_until_subscriber_role(session, pid, expected_role, attempts - 1)
    end
  end

  def wait_until_subscriber_role(_session, _pid, _expected_role, 0), do: :ok

  @spec native_provider_opts(module(), keyword()) :: keyword()
  defp native_provider_opts(MingaAgent.Providers.Native, provider_opts) do
    provider_opts
    |> Keyword.put_new(:provider, "anthropic")
    |> Keyword.put_new(:model, "anthropic:test")
  end

  defp native_provider_opts(_provider, provider_opts), do: provider_opts
end
