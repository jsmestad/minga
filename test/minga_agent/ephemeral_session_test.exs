defmodule MingaAgent.EphemeralSessionTest do
  use ExUnit.Case, async: true

  alias MingaAgent.EphemeralSession

  test "ask starts a non-persistent read-only no-tool session with hooks disabled" do
    parent = self()

    manager =
      spawn_link(fn ->
        receive do
          {:"$gen_call", from, {:start_session, opts}} ->
            send(parent, {:start_session_opts, opts})
            GenServer.reply(from, {:error, :captured})
        end
      end)

    assert {:error, :captured} =
             EphemeralSession.ask("why?", "/tmp/project",
               session_manager: manager,
               subscriber: self()
             )

    assert_receive {:start_session_opts, opts}
    assert opts[:session_store_dir] == nil
    assert opts[:persist?] == false
    assert opts[:hooks_enabled?] == false
    assert opts[:startup_notice] == nil

    provider_opts = opts[:provider_opts]
    assert provider_opts[:project_root] == "/tmp/project"
    assert provider_opts[:read_only?] == true
    assert provider_opts[:tool_allowlist] == []
    assert provider_opts[:tools] == []
  end
end
