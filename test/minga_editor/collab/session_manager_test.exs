defmodule MingaEditor.Collab.SessionManagerTest do
  @moduledoc """
  Acceptance-level coverage for the collab MVP (#2424): the headless daemon
  hosts N independent editor sessions sharing the node-local buffer registry.

  Uses the headless backend so the triad runs without a renderer Port (headless
  renders in-process); the editor GenServer and its isolated state are the part
  under test here.
  """

  # async: false because it starts the globally-named SessionManager
  # DynamicSupervisor and registers editors in the node-shared Collab.Registry.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Collab.Names
  alias MingaEditor.Collab.SessionManager

  setup do
    start_supervised!(SessionManager)
    :ok
  end

  defp unique_session(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, retries - 1)
    end
  end

  describe "start_session/2" do
    test "starts an independent editor triad for a non-default session" do
      session_id = unique_session("client")

      assert {:ok, sup} = SessionManager.start_session(session_id, backend: :headless)
      assert is_pid(sup)
      assert SessionManager.session_running?(session_id)

      editor = Names.whereis(session_id, :editor)
      assert is_pid(editor)
      assert Process.alive?(editor)

      SessionManager.stop_session(session_id)
    end

    test "is idempotent for an already-running session" do
      session_id = unique_session("client")

      assert {:ok, sup} = SessionManager.start_session(session_id, backend: :headless)
      assert {:ok, ^sup} = SessionManager.start_session(session_id, backend: :headless)

      SessionManager.stop_session(session_id)
    end

    test "refuses to spin up a managed triad for the default session" do
      # No default triad is running in test (Runtime.Supervisor is off), so this
      # reports the default session as not running rather than starting a managed one.
      assert {:error, :not_running} = SessionManager.start_session(Names.default_session_id())
    end

    test "two clients get distinct, independent editors" do
      a = unique_session("client-a")
      b = unique_session("client-b")

      {:ok, _} = SessionManager.start_session(a, backend: :headless)
      {:ok, _} = SessionManager.start_session(b, backend: :headless)

      editor_a = Names.whereis(a, :editor)
      editor_b = Names.whereis(b, :editor)

      assert is_pid(editor_a)
      assert is_pid(editor_b)
      assert editor_a != editor_b

      SessionManager.stop_session(a)
      SessionManager.stop_session(b)
    end
  end

  describe "stop_session/1" do
    test "tears down the triad and unregisters the editor" do
      session_id = unique_session("client")
      {:ok, sup} = SessionManager.start_session(session_id, backend: :headless)
      ref = Process.monitor(sup)

      assert :ok = SessionManager.stop_session(session_id)
      assert_receive {:DOWN, ^ref, :process, ^sup, _reason}, 2_000

      refute SessionManager.session_running?(session_id)
      # Registry deregistration of the dead editor is eventual (the Registry
      # processes the editor's :DOWN asynchronously), so poll for it.
      assert eventually(fn -> Names.whereis(session_id, :editor) == nil end)
    end

    test "is a no-op for a session that was never started" do
      assert :ok = SessionManager.stop_session(unique_session("never"))
    end

    test "never tears down the default session" do
      assert :ok = SessionManager.stop_session(Names.default_session_id())
    end
  end

  describe "shared buffers across sessions" do
    test "two sessions opening the same path resolve to one Buffer.Process" do
      a = unique_session("client-a")
      b = unique_session("client-b")
      {:ok, _} = SessionManager.start_session(a, backend: :headless)
      {:ok, _} = SessionManager.start_session(b, backend: :headless)

      path =
        Path.join(System.tmp_dir!(), "collab-shared-#{System.unique_integer([:positive])}.txt")

      File.write!(path, "shared content\n")
      on_exit(fn -> File.rm(path) end)

      # Each session's editor opens the same path. The node-shared
      # Minga.Buffer.Registry is keyed by absolute path, so both editors end up
      # tracking the same Buffer.Process.
      {:ok, buf_a} = MingaEditor.ensure_buffer_for_path(path, Names.whereis(a, :editor))
      {:ok, buf_b} = MingaEditor.ensure_buffer_for_path(path, Names.whereis(b, :editor))

      assert buf_a == buf_b
      assert Process.alive?(buf_a)

      # Confirm it is the registry-owned process for that path.
      assert {:ok, buf_a} == BufferProcess.pid_for_path(path)

      SessionManager.stop_session(a)
      SessionManager.stop_session(b)
    end
  end
end
