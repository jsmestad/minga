defmodule MingaEditor.CollabTest do
  @moduledoc """
  Lifecycle coverage for the collab attach/detach seam (#2424): attaching a
  client to an agent session also stands up that client's server-side editor,
  and detaching tears it down.
  """

  # async: false: starts the global MingaEditor.Collab.SessionManager and uses
  # the global MingaAgent.SessionManager broker.
  use ExUnit.Case, async: false

  alias MingaAgent.RemoteAPI
  alias MingaAgent.SessionManager, as: AgentSessionManager
  alias MingaEditor.Collab
  alias MingaEditor.Collab.Names
  alias MingaEditor.Collab.SessionManager, as: EditorSessionManager

  setup do
    start_supervised!(EditorSessionManager)

    {:ok, %{session_id: agent_session_id, token: token}} = RemoteAPI.start_session([])
    on_exit(fn -> AgentSessionManager.stop_session(agent_session_id) end)

    %{agent_session_id: agent_session_id, token: token}
  end

  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  test "attach starts a per-client server-side editor and returns its id", %{
    agent_session_id: agent_session_id,
    token: token
  } do
    client = idle_process()
    on_exit(fn -> Process.exit(client, :kill) end)

    assert {:ok, result} =
             Collab.attach(agent_session_id, token, client, role: :driver, backend: :headless)

    editor_session_id = result.editor_session_id
    assert is_binary(editor_session_id)
    assert editor_session_id == RemoteAPI.editor_session_id(agent_session_id, client)

    assert EditorSessionManager.session_running?(editor_session_id)
    assert is_pid(Names.whereis(editor_session_id, :editor))

    Collab.detach(agent_session_id, token, client)
  end

  test "two clients on one host get distinct server-side editors", %{
    agent_session_id: agent_session_id,
    token: token
  } do
    a = idle_process()
    b = idle_process()
    on_exit(fn -> Enum.each([a, b], &Process.exit(&1, :kill)) end)

    assert {:ok, ra} =
             Collab.attach(agent_session_id, token, a, role: :driver, backend: :headless)

    assert {:ok, rb} =
             Collab.attach(agent_session_id, token, b, role: :viewer, backend: :headless)

    refute ra.editor_session_id == rb.editor_session_id

    editor_a = Names.whereis(ra.editor_session_id, :editor)
    editor_b = Names.whereis(rb.editor_session_id, :editor)
    assert is_pid(editor_a)
    assert is_pid(editor_b)
    assert editor_a != editor_b

    Collab.detach(agent_session_id, token, a)
    Collab.detach(agent_session_id, token, b)
  end

  test "detach tears down the client's server-side editor", %{
    agent_session_id: agent_session_id,
    token: token
  } do
    client = idle_process()
    on_exit(fn -> Process.exit(client, :kill) end)

    {:ok, result} =
      Collab.attach(agent_session_id, token, client, role: :driver, backend: :headless)

    editor = Names.whereis(result.editor_session_id, :editor)
    ref = Process.monitor(editor)

    assert :ok = Collab.detach(agent_session_id, token, client)
    assert_receive {:DOWN, ^ref, :process, ^editor, _reason}, 2_000

    refute EditorSessionManager.session_running?(result.editor_session_id)
  end

  test "detach is safe when no editor session was started", %{
    agent_session_id: agent_session_id,
    token: token
  } do
    client = idle_process()
    on_exit(fn -> Process.exit(client, :kill) end)

    # Never attached, so no triad exists; detach must not raise.
    assert :ok = Collab.detach(agent_session_id, token, client)
  end
end
