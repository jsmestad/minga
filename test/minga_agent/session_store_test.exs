defmodule MingaAgent.SessionStoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Branch
  alias MingaAgent.SessionStore
  alias MingaAgent.ToolCall
  alias MingaAgent.TurnUsage

  @moduletag :tmp_dir

  defp sample_data(id \\ "test-session-1") do
    %{
      id: id,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      last_message_at: DateTime.to_iso8601(DateTime.utc_now()),
      title: "Hello, how are you?",
      model_name: "claude-sonnet-4",
      provider_name: "native",
      messages: [
        {:system, "Session started", :info},
        {:user, "Hello, how are you?"},
        {:assistant, "I'm doing great!"},
        {:tool_call,
         %ToolCall{
           id: "tc1",
           name: "read_file",
           args: %{"path" => "lib/foo.ex"},
           status: :complete,
           result: "defmodule Foo do\nend",
           is_error: false,
           collapsed: true,
           auto_approved_scope: :session,
           started_at: nil,
           duration_ms: 42
         }},
        {:thinking, "Let me think about this...", true},
        {:usage, %TurnUsage{input: 100, output: 50, cache_read: 200, cache_write: 0, cost: 0.003}}
      ],
      usage: %TurnUsage{input: 100, output: 50, cache_read: 200, cache_write: 0, cost: 0.003},
      branches: [Branch.new("branch-1", [{:user, "branch prompt"}])],
      memory: "- [2026-01-01 00:00 UTC] Use concise answers\n"
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

    test "preserves user message attachments" do
      data = %{
        sample_data()
        | messages: [{:user, "see image", [%{filename: "chart.png", size_kb: 42}]}]
      }

      SessionStore.save(data)

      {:ok, loaded} = SessionStore.load(data.id)
      assert loaded.messages == [{:user, "see image", [%{filename: "chart.png", size_kb: 42}]}]
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
      assert tc.auto_approved_scope == :session
    end

    test "loads corrupted message atoms defensively", %{tmp_dir: dir} do
      sessions_dir = SessionStore.sessions_dir(dir)
      File.mkdir_p!(sessions_dir)

      File.write!(
        Path.join(sessions_dir, "bad-atoms.json"),
        JSON.encode!(%{
          "id" => "bad-atoms",
          "timestamp" => "2026-01-01T00:00:00Z",
          "model_name" => "test-model",
          "messages" => [
            %{"type" => "system", "text" => "bad level", "level" => "surprise"},
            %{"type" => "tool_call", "id" => "tc", "name" => "read_file", "status" => "surprise"}
          ],
          "usage" => %{}
        })
      )

      assert {:ok, loaded} = SessionStore.load("bad-atoms", dir)
      assert {:system, "bad level", :info} in loaded.messages
      assert {:tool_call, %{status: :complete}} = List.last(loaded.messages)
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

    test "preserves resumable metadata, branches, and memory", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      {:ok, loaded} = SessionStore.load(data.id, dir)
      assert loaded.title == "Hello, how are you?"
      assert loaded.provider_name == "native"
      assert [%Branch{name: "branch-1", messages: [{:user, "branch prompt"}]}] = loaded.branches
      assert loaded.memory =~ "Use concise answers"
    end

    test "writes session directory and files with private permissions", %{tmp_dir: dir} do
      data = Map.put(sample_data("private-session"), :remote_token, "remote-token")
      assert :ok = SessionStore.save(data, dir)

      sessions_dir = SessionStore.sessions_dir(dir)
      session_path = Path.join(sessions_dir, "private-session.json")

      assert private_mode?(File.stat!(sessions_dir).mode, 0o077)
      assert private_mode?(File.stat!(session_path).mode, 0o077)
    end

    test "returns error for nonexistent session" do
      assert {:error, _} = SessionStore.load("nonexistent-id")
    end

    test "returns error when the sessions directory cannot be created", %{tmp_dir: dir} do
      blocked_base = Path.join(dir, "not-a-directory")
      File.write!(blocked_base, "file blocks mkdir")

      assert {:error, _reason} = SessionStore.save(sample_data("blocked"), blocked_base)
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

    test "metadata includes title, last message timestamp, turn count, and recent text", %{
      tmp_dir: dir
    } do
      data = sample_data()
      SessionStore.save(data, dir)

      sessions = SessionStore.list(dir)
      session = Enum.find(sessions, &(&1.id == data.id))
      assert session.title == "Hello, how are you?"
      assert session.last_message_at == data.last_message_at
      assert session.turn_count == 1
      assert session.recent_messages =~ "doing great"
    end

    test "sorts sessions by last message timestamp descending", %{tmp_dir: dir} do
      old_data = %{
        sample_data("old")
        | timestamp: "2026-01-01T00:00:00Z",
          last_message_at: "2026-01-01T00:00:00Z"
      }

      new_data = %{
        sample_data("new")
        | timestamp: "2026-01-01T00:00:00Z",
          last_message_at: "2026-01-03T00:00:00Z"
      }

      middle_data = %{
        sample_data("middle")
        | timestamp: "2026-01-01T00:00:00Z",
          last_message_at: "2026-01-02T00:00:00Z"
      }

      SessionStore.save(old_data, dir)
      SessionStore.save(new_data, dir)
      SessionStore.save(middle_data, dir)

      assert SessionStore.list(dir) |> Enum.map(& &1.id) == ["new", "middle", "old"]
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

  @spec private_mode?(non_neg_integer(), non_neg_integer()) :: boolean()
  defp private_mode?(mode, mask) do
    Bitwise.band(mode, mask) == 0
  end
end
