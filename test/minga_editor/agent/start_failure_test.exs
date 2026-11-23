defmodule MingaEditor.Agent.StartFailureTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session.{ConnectionSnapshot, ConnectionTarget}
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.StartRequest

  @request StartRequest.new(false, true, {:seed, [{:user, "hello"}]})

  # A pid on another node, without starting distribution.
  defp remote_pid do
    node = "remote@host"
    :erlang.binary_to_term(<<131, 88, 119, byte_size(node), node::binary, 1::32, 0::32, 1::32>>)
  end

  defp connection(readiness) do
    %ConnectionSnapshot{
      target: ConnectionTarget.new(self(), "session", nil, make_ref()),
      credential_readiness: readiness,
      model_selection: nil,
      provider_phase: :terminal_failure,
      operation: :idle,
      problem: {:provider, :startup_failed}
    }
  end

  test "each cause offers one remedy and a plain sentence without Elixir terms" do
    for {failure, remedy} <- [
          {StartFailure.catalog_unavailable(@request), {:retry, @request}},
          {StartFailure.timed_out(@request), {:retry, @request}},
          {StartFailure.session_error({:noproc, {GenServer, :call, []}}, @request),
           {:retry, @request}},
          {StartFailure.session_error(:noproc, @request), {:retry, @request}},
          {StartFailure.session_error({:badmatch, %{a: 1}}, @request), {:retry, @request}},
          {StartFailure.no_workspace(@request), {:retry, @request}},
          {StartFailure.session_crashed(self()), {:retry, StartRequest.default()}},
          {StartFailure.session_crashed(remote_pid()), nil},
          {StartFailure.provider_startup_failed(connection(:configured)), {:retry, :provider}},
          {StartFailure.provider_startup_failed(connection(:checking)), {:retry, :provider}},
          {StartFailure.provider_startup_failed(connection(:unconfigured)), :set_up_provider},
          {StartFailure.missing_credentials(), :set_up_provider}
        ] do
      assert failure.remedy == remedy
      assert failure.message =~ ~r/^[A-Z][^{}%:#<>]*\.$/
    end
  end

  test "a session error never shows the raw reason" do
    failure = StartFailure.session_error({:shutdown, :secret_detail}, @request)
    refute failure.message =~ "secret_detail"
    refute failure.message =~ "shutdown"
  end
end
