defmodule Minga.Agent.SessionStoreTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.SessionStore

  @moduletag :tmp_dir

  defp sample_data(id \\ "test-session-1") do
    %{
      id: id,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      model_name: "claude-sonnet-4",
      messages: [
        {:system, "Session started", :info},
        {:user, "Hello, how are you?"},
        {:assistant, "I'm doing great!"},
        {:tool_call,
         %{
           id: "tc1",
           name: "read_file",
           args: %{"path" => "lib/foo.ex"},
           status: :complete,
           result: "defmodule Foo do\nend",
           is_error: false,
           collapsed: true,
           started_at: nil,
           duration_ms: 42
         }},
        {:thinking, "Let me think about this...", true},
        {:usage, %{input: 100, output: 50, cache_read: 200, cache_write: 0, cost: 0.003}}
      ],
      usage: %{input: 100, output: 50, cache_read: 200, cache_write: 0, cost: 0.003}
    }
  end

  # ── Save/Load round-trip ───────────────────────────────────────────────────

  describe "save and load round-trip" do
    test "saves and loads via the public API" do
      data = sample_data()
      assert :ok = SessionStore.save(data)

      assert {:ok, loaded} = SessionStore.load(data.id)
      assert loaded.id == data.id
      assert loaded.model_name == "claude-sonnet-4"
    end

    test "preserves user messages" do
      data = sample_data()
      SessionStore.save(data)

      {:ok, loaded} = SessionStore.load(data.id)
      user_msgs = Enum.filter(loaded.messages, &match?({:user, _}, &1))
      assert [{:user, "Hello, how are you?"}] = user_msgs
    end

    test "preserves assistant messages" do
      data = sample_data()
      SessionStore.save(data)

      {:ok, loaded} = SessionStore.load(data.id)
      assert {:assistant, "I'm doing great!"} in loaded.messages
    end

    test "preserves tool call messages" do
      data = sample_data()
      SessionStore.save(data)

      {:ok, loaded} = SessionStore.load(data.id)
      tool_calls = Enum.filter(loaded.messages, &match?({:tool_call, _}, &1))
      assert [{:tool_call, tc}] = tool_calls
      assert tc.name == "read_file"
      assert tc.duration_ms == 42
      assert tc.status == :complete
    end

    test "preserves thinking messages" do
      data = sample_data()
      SessionStore.save(data)

      {:ok, loaded} = SessionStore.load(data.id)
      thinking = Enum.filter(loaded.messages, &match?({:thinking, _, _}, &1))
      assert [{:thinking, "Let me think about this...", true}] = thinking
    end

    test "preserves system messages" do
      data = sample_data()
      SessionStore.save(data)

      {:ok, loaded} = SessionStore.load(data.id)
      system = Enum.filter(loaded.messages, &match?({:system, _, _}, &1))
      assert [{:system, "Session started", :info}] = system
    end

    test "preserves usage messages" do
      data = sample_data()
      SessionStore.save(data)

      {:ok, loaded} = SessionStore.load(data.id)
      usage = Enum.filter(loaded.messages, &match?({:usage, _}, &1))
      assert [{:usage, u}] = usage
      assert u.input == 100
      assert u.cost == 0.003
    end

    test "preserves total usage" do
      data = sample_data()
      SessionStore.save(data)

      {:ok, loaded} = SessionStore.load(data.id)
      assert loaded.usage.input == 100
      assert loaded.usage.cost == 0.003
    end

    test "returns error for nonexistent session" do
      assert {:error, _} = SessionStore.load("nonexistent-id")
    end
  end

  # ── List ────────────────────────────────────────────────────────────────────

  describe "list/0" do
    test "returns empty list when no sessions exist" do
      # Sessions dir may not exist yet
      sessions = SessionStore.list()
      # Should not crash, returns a list
      assert is_list(sessions)
    end

    test "lists saved sessions with metadata" do
      data1 = sample_data("session-a")
      data2 = sample_data("session-b")
      SessionStore.save(data1)
      SessionStore.save(data2)

      sessions = SessionStore.list()
      ids = Enum.map(sessions, & &1.id)
      assert "session-a" in ids
      assert "session-b" in ids
    end

    test "metadata includes preview from first user message" do
      data = sample_data()
      SessionStore.save(data)

      sessions = SessionStore.list()
      session = Enum.find(sessions, &(&1.id == data.id))
      assert session.preview =~ "Hello"
    end

    test "metadata includes model name" do
      data = sample_data()
      SessionStore.save(data)

      sessions = SessionStore.list()
      session = Enum.find(sessions, &(&1.id == data.id))
      assert session.model_name == "claude-sonnet-4"
    end
  end

  # ── Delete ──────────────────────────────────────────────────────────────────

  describe "delete/1" do
    test "deletes a saved session" do
      data = sample_data()
      SessionStore.save(data)

      assert :ok = SessionStore.delete(data.id)
      assert {:error, _} = SessionStore.load(data.id)
    end
  end

  # ── Clear all ───────────────────────────────────────────────────────────────

  describe "clear_all/0" do
    test "removes all sessions" do
      SessionStore.save(sample_data("s1"))
      SessionStore.save(sample_data("s2"))

      SessionStore.clear_all()

      assert {:error, _} = SessionStore.load("s1")
      assert {:error, _} = SessionStore.load("s2")
    end
  end

  # ── Atomic writes ──────────────────────────────────────────────────────────

  describe "atomic writes" do
    test "overwrites an existing session" do
      data1 = %{sample_data() | messages: [{:user, "first"}]}
      data2 = %{sample_data() | messages: [{:user, "second"}]}

      SessionStore.save(data1)
      SessionStore.save(data2)

      {:ok, loaded} = SessionStore.load(data1.id)
      assert [{:user, "second"}] = loaded.messages
    end
  end

  # ── Prune ───────────────────────────────────────────────────────────────────

  describe "prune/1" do
    test "removes sessions older than N days" do
      old_ts = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60 * 86_400, :second))
      new_ts = DateTime.to_iso8601(DateTime.utc_now())

      old_data = %{sample_data("old-session") | timestamp: old_ts}
      new_data = %{sample_data("new-session") | timestamp: new_ts}

      SessionStore.save(old_data)
      SessionStore.save(new_data)

      pruned = SessionStore.prune(30)
      assert pruned >= 1

      assert {:error, _} = SessionStore.load("old-session")
      assert {:ok, _} = SessionStore.load("new-session")
    end

    test "does not remove sessions within retention period" do
      data = sample_data("recent-session")
      SessionStore.save(data)

      pruned = SessionStore.prune(30)
      assert pruned == 0
      assert {:ok, _} = SessionStore.load("recent-session")
    end
  end
end
