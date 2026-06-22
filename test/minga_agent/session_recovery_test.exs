defmodule MingaAgent.SessionRecoveryTest do
  use ExUnit.Case, async: true

  alias Minga.Test.StubProvider
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session

  defp start_credential_checker(initial_state) do
    checker =
      {Agent, fn -> initial_state end}
      |> Supervisor.child_spec(id: {:credential_checker, make_ref()})
      |> start_supervised!()

    {checker, fn -> Agent.get(checker, & &1) end}
  end

  defp start_session(opts, initial_credentials_state) do
    {checker, credentials_configured_fn} = start_credential_checker(initial_credentials_state)

    provider_opts =
      Keyword.get(opts, :provider_opts, [])
      |> Keyword.merge(skip_api_key_env: true)

    {:ok, session} =
      Session.start_link(
        opts
        |> Keyword.put(:provider_opts, provider_opts)
        |> Keyword.put(:credentials_configured_fn, credentials_configured_fn)
      )

    {session, checker}
  end

  defmodule FailingProvider do
    @behaviour MingaAgent.Provider

    @impl MingaAgent.Provider
    def start_link(_opts), do: {:error, {:spawn_failed, "boom"}}

    @impl MingaAgent.Provider
    def send_prompt(_pid, _text), do: :ok

    @impl MingaAgent.Provider
    def abort(_pid), do: :ok

    @impl MingaAgent.Provider
    def new_session(_pid), do: :ok

    @impl MingaAgent.Provider
    def seed_messages(_pid, _messages), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil}}
  end

  test "refresh_credentials/1 starts a provider only after credentials flip true and model is concrete" do
    {session, checker} =
      start_session(
        [provider: Native, provider_opts: [model: AgentConfig.unconfigured_model()]],
        false
      )

    assert Session.get_provider(session) == nil
    assert Session.editor_snapshot(session).credentials_configured == false
    assert {:error, :credentials_not_configured} = Session.send_prompt(session, "draft prompt")

    assert :ok = Session.set_model(session, "anthropic:claude-sonnet-4-20250514")
    assert Session.get_provider(session) == nil

    Agent.update(checker, fn _ -> true end)
    assert :ok = Session.refresh_credentials(session)
    assert Session.editor_snapshot(session).credentials_configured == true
    assert is_pid(Session.get_provider(session))
  end

  test "set_model/2 can recover a provider-less session when credentials already exist" do
    {session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: AgentConfig.unconfigured_model()]],
        true
      )

    assert Session.get_provider(session) == nil
    assert :ok = Session.set_model(session, "claude-opus-4-20250514@anthropic")
    assert is_pid(Session.get_provider(session))

    metadata = Session.metadata(session)
    assert metadata.model_name == "claude-opus-4-20250514@anthropic"
    assert metadata.provider_name == "anthropic"
    assert Session.subagent_context(session).provider_name == "anthropic"
  end

  test "subagent_context uses session provider metadata for native providers" do
    {session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: "claude-opus-4-20250514@anthropic"]],
        true
      )

    assert is_pid(Session.get_provider(session))
    assert Session.subagent_context(session).provider_name == "anthropic"
  end

  test "set_model/2 returns startup errors when refresh triggers a failing provider" do
    {checker, credentials_configured_fn} = start_credential_checker(false)

    {:ok, session} =
      Session.start_link(
        provider: FailingProvider,
        provider_opts: [model: AgentConfig.unconfigured_model(), skip_api_key_env: true],
        credentials_configured_fn: credentials_configured_fn
      )

    Agent.update(checker, fn _ -> true end)

    assert {:error, "Failed to start agent: boom"} =
             Session.set_model(session, "anthropic:claude-sonnet-4-20250514")

    assert Session.get_provider(session) == nil
  end

  test "custom providers still start when the top-level model name is unknown" do
    {session, _checker} =
      start_session(
        [provider: StubProvider, provider_opts: [model: AgentConfig.unconfigured_model()]],
        false
      )

    assert is_pid(Session.get_provider(session))
  end

  test "subscribe/2 sends the current credentials status to new subscribers" do
    {unconfigured_session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: AgentConfig.unconfigured_model()]],
        false
      )

    assert :ok = Session.subscribe(unconfigured_session, self())
    assert_receive {:agent_event, ^unconfigured_session, {:credentials_status, false}}

    {configured_session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: "anthropic:claude-sonnet-4-20250514"]],
        true
      )

    assert :ok = Session.subscribe(configured_session, self())
    assert_receive {:agent_event, ^configured_session, {:credentials_status, true}}
  end

  test "set_model/2 updates provider metadata for provider-qualified models" do
    {session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: AgentConfig.unconfigured_model()]],
        false
      )

    assert :ok = Session.set_model(session, "anthropic:claude-sonnet-4-20250514")
    metadata = Session.metadata(session)

    assert metadata.model_name == "anthropic:claude-sonnet-4-20250514"
    assert metadata.provider_name == "anthropic"
    assert Session.subagent_context(session).provider_name == "anthropic"
  end

  test "provider opts seed the stored model name when top-level model_name is absent" do
    {session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: "anthropic:claude-sonnet-4-20250514"]],
        true
      )

    assert is_pid(Session.get_provider(session))
    assert Session.metadata(session).model_name == "anthropic:claude-sonnet-4-20250514"
    assert Session.metadata(session).provider_name == "anthropic"
  end

  test "provider opts still start when top-level model_name is unknown" do
    {session, _checker} =
      start_session(
        [
          provider: Native,
          model_name: AgentConfig.unconfigured_model(),
          provider_opts: [model: "anthropic:claude-sonnet-4-20250514"]
        ],
        true
      )

    assert is_pid(Session.get_provider(session))
    assert Session.metadata(session).model_name == "anthropic:claude-sonnet-4-20250514"
  end
end
