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

  test "rewrite starts a non-persistent read-only constrained-tool session with hooks disabled" do
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
             EphemeralSession.rewrite("rewrite this", File.cwd!(),
               session_manager: manager,
               subscriber: self()
             )

    assert_receive {:start_session_opts, opts}
    assert opts[:session_store_dir] == nil
    assert opts[:persist?] == false
    assert opts[:hooks_enabled?] == false
    assert opts[:startup_notice] == nil

    provider_opts = opts[:provider_opts]
    names = Enum.map(provider_opts[:tools], & &1.name)
    assert provider_opts[:read_only?] == true
    assert provider_opts[:tool_allowlist] == names
    assert names == ["read_file", "list_directory", "find", "grep", "produce_rewrite"]
    refute "diagnostics" in names
    refute "definition" in names
    refute "git_status" in names
    refute "write_file" in names
    refute "multi_edit_file" in names
    refute "apply_diff" in names
    refute "shell" in names
    refute "delete_file" in names
  end
end
