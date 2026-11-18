defmodule MingaAgent.Session.ConnectionSnapshotTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.ConnectionTarget
  alias MingaAgent.Session.ProviderLifecycle

  test "readiness reports local prerequisites, never authentication or task completion" do
    provider = provider()
    target = ConnectionTarget.new(self(), "session", nil, make_ref())
    stopped = ConnectionSnapshot.new(target, :configured, nil, provider, :idle, nil)
    assert stopped.provider_phase == :stopped
    assert ConnectionSnapshot.status(stopped) == :connecting
    {:start, starting, nil} = ProviderLifecycle.start(provider)

    assert ConnectionSnapshot.status(
             ConnectionSnapshot.new(target, :configured, nil, starting, :idle, nil)
           ) == :connecting

    {:ok, running} = ProviderLifecycle.attach(starting, self(), make_ref())
    ready = ConnectionSnapshot.new(target, :configured, nil, running, :idle, nil)
    assert ConnectionSnapshot.status(ready) == :ready
    assert ready.credential_readiness == :configured
    assert ready.provider_phase == :running

    assert ConnectionSnapshot.status(
             ConnectionSnapshot.new(target, :unconfigured, nil, running, :idle, nil)
           ) == :unconfigured

    assert ConnectionSnapshot.status(
             ConnectionSnapshot.new(target, :checking, nil, running, :idle, nil)
           ) == :checking

    ref = make_ref()
    pending = ConnectionSnapshot.new(target, :configured, nil, running, {:connecting, ref}, nil)
    assert pending.operation == {:connecting, ref}
    assert ConnectionSnapshot.status(pending) == :connecting
  end

  test "all structured connection problems project without parsing their text" do
    target = ConnectionTarget.new(self(), "session", nil, make_ref())

    for {problem, expected} <- [
          {{:resolution, :no_available_model}, :unconfigured},
          {{:resolution, {:credential_unavailable, "not an auth message"}}, :credential_failure},
          {{:resolution, {:route_unavailable, "auth failed"}}, :unsupported},
          {{:resolution, {:backend_unavailable, "backend"}}, :unsupported},
          {{:resolution, {:model_not_found, "model"}}, :unsupported},
          {{:resolution, {:invalid_model_selection, "model"}}, :unsupported},
          {{:resolution, {:incompatible_selection, "model"}}, :unsupported},
          {{:resolution, {:selection_correction_required, "model"}}, :unsupported},
          {{:provider, :auth_failed}, :credential_failure},
          {{:provider, :rate_limited}, :provider_failure},
          {{:provider, :unreachable}, :provider_failure},
          {{:provider, :invalid_model}, :provider_failure},
          {{:provider, :provider_error}, :provider_failure},
          {{:provider, :startup_failed}, :provider_failure}
        ] do
      snapshot = ConnectionSnapshot.new(target, :configured, nil, provider(), :idle, problem)
      assert snapshot.problem == problem
      assert ConnectionSnapshot.status(snapshot) == expected
    end
  end

  test "retrying and terminal phases remain distinct even without display errors" do
    target = ConnectionTarget.new(self(), "session", nil, make_ref())
    {:start, starting, nil} = ProviderLifecycle.start(provider())
    {:failed, failed, _lease} = ProviderLifecycle.failure(starting, :failure)
    {:retry, retrying, _delay} = ProviderLifecycle.retry(failed, :failure, 0)

    assert ConnectionSnapshot.status(
             ConnectionSnapshot.new(target, :configured, nil, retrying, :idle, nil)
           ) == :connecting

    terminal_provider = provider(max_attempts: 0)
    {:start, starting, nil} = ProviderLifecycle.start(terminal_provider)
    {:failed, failed, _lease} = ProviderLifecycle.failure(starting, :failure)
    assert {:terminal_failure, terminal} = ProviderLifecycle.retry(failed, :failure, 0)

    assert ConnectionSnapshot.status(
             ConnectionSnapshot.new(target, :configured, nil, terminal, :idle, nil)
           ) == :provider_failure
  end

  test "targets include exact route, credential profile and source identity without credential bytes" do
    alias MingaAgent.ModelSelection
    alias MingaAgent.ModelSelection.Credential.OAuth
    alias MingaAgent.Test.ModelSelectionFixture

    epoch = make_ref()

    selections = [
      ModelSelectionFixture.selection(),
      ModelSelectionFixture.selection(model_id: "different-model"),
      ModelSelectionFixture.selection(
        request_provider: :openai_codex,
        credential: OAuth.new("account-a", "/private/synthetic/oauth-a.json")
      ),
      ModelSelectionFixture.selection(
        request_provider: :openai_codex,
        credential: OAuth.new("account-b", "/private/synthetic/oauth-a.json")
      ),
      ModelSelectionFixture.selection(
        request_provider: :openai_codex,
        credential: OAuth.new("account-a", "/private/synthetic/oauth-b.json")
      )
    ]

    targets = Enum.map(selections, &ConnectionTarget.new(self(), "session", &1, epoch))
    assert length(Enum.uniq(targets)) == length(selections)

    for {selection, target} <- Enum.zip(selections, targets) do
      assert target.selection_id == ModelSelection.id(selection)
      assert target.credential_id == ModelSelection.credential_id(selection.credential)
    end
  end

  defp provider(restart \\ []) do
    ProviderLifecycle.new(
      module: Minga.Test.StubProvider,
      id: "test",
      source: :builtin,
      provider_opts: [],
      model_name: "model",
      provider_name: "test",
      restart: restart
    )
  end
end
