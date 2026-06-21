defmodule MingaEditor.Collab.NamesTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Collab.Names

  describe "default session" do
    test "default_session_id is stable" do
      assert Names.default_session_id() == "default"
      assert Names.default_session?("default")
      refute Names.default_session?("client-1")
    end

    test "name/2 returns bare module names for the default session" do
      assert Names.name("default", :editor) == MingaEditor
      assert Names.name("default", :frontend) == MingaEditor.Frontend.Manager
      assert Names.name("default", :renderer) == MingaEditor.Renderer.Server
    end
  end

  describe "non-default session" do
    test "name/2 returns a via-tuple keyed by {session_id, role}" do
      assert Names.name("client-1", :editor) ==
               {:via, Registry, {Names.registry(), {"client-1", :editor}}}

      assert Names.name("client-1", :renderer) ==
               {:via, Registry, {Names.registry(), {"client-1", :renderer}}}
    end

    test "via/2 always returns a via-tuple, even for the default session" do
      assert Names.via("default", :editor) ==
               {:via, Registry, {Names.registry(), {"default", :editor}}}
    end
  end

  describe "whereis/2" do
    test "returns nil for a session with no registered process" do
      assert Names.whereis("absent-session", :editor) == nil
    end

    test "resolves a process registered under the via-tuple" do
      session_id = "names-test-#{System.unique_integer([:positive])}"
      via = Names.via(session_id, :editor)

      {:ok, pid} = Agent.start_link(fn -> :ok end, name: via)

      assert Names.whereis(session_id, :editor) == pid
    end
  end

  describe "list_session_ids/0" do
    test "includes sessions with a registered editor" do
      session_id = "names-list-#{System.unique_integer([:positive])}"
      via = Names.via(session_id, :editor)
      {:ok, _pid} = Agent.start_link(fn -> :ok end, name: via)

      assert session_id in Names.list_session_ids()
    end
  end
end
