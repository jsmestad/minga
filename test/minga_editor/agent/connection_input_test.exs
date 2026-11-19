defmodule MingaEditor.Agent.ConnectionInputTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Credentials
  alias MingaAgent.Credentials.Secret
  alias MingaAgent.Session
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaEditor.Agent.ConnectionInput

  @moduletag :tmp_dir
  @method {:api_key, "openai"}

  setup %{tmp_dir: directory} do
    opts = [config_dir: directory, oauth_path: Path.join(directory, "oauth.json"), env: %{}]

    session =
      start_supervised!(
        {Session,
         provider: Minga.Test.SessionMockProvider,
         provider_opts: [credential_opts: opts],
         persist?: false,
         hooks_enabled?: false,
         session_start_hook_enabled?: false,
         recover_interrupted_work?: false}
      )

    target = Session.editor_snapshot(session).connection.target
    {:ok, operation} = Session.begin_connection(session, target, @method, self())
    supervisor = start_supervised!({Task.Supervisor, []})
    %{opts: opts, session: session, target: target, operation: operation, supervisor: supervisor}
  end

  test "unjoined input can be discarded without writing or sending a prompt", context do
    messages = Session.messages(context.session)
    {:ok, worker, receipt} = start_holder(context, "discarded-key")
    monitor = Process.monitor(worker)
    assert :ok = ConnectionInput.abort(worker, receipt)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    assert :error = Credentials.resolve("openai", context.opts)
    assert Session.messages(context.session) == messages
  end

  test "joining a live operation persists exactly once and never sends a prompt", context do
    messages = Session.messages(context.session)
    {:ok, worker, receipt} = start_holder(context, "synthetic-key")

    assert {:ok, %ConnectionSnapshot{credential_readiness: :configured, operation: :idle}} =
             ConnectionInput.await(worker, receipt)

    assert {:ok, "synthetic-key", :file} = Credentials.resolve("openai", context.opts)
    assert {:error, :input_worker_unavailable} = ConnectionInput.await(worker, receipt)
    assert Session.messages(context.session) == messages
  end

  test "joining after cancellation refuses the write and retains the prior key", context do
    assert :ok = Credentials.store("openai", "synthetic-prior", context.opts)
    assert :ok = Session.cancel_connection(context.session, context.target, context.operation)
    {:ok, worker, receipt} = start_holder(context, "synthetic-late")
    assert {:error, :cancelled} = ConnectionInput.await(worker, receipt)
    assert {:ok, "synthetic-prior", :file} = Credentials.resolve("openai", context.opts)
  end

  defp start_holder(context, key) do
    ConnectionInput.start(
      context.supervisor,
      self(),
      context.target,
      context.operation,
      @method,
      Secret.new(key)
    )
  end
end
