defmodule MingaAgent.AutobiographyTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Autobiography
  alias MingaAgent.Autobiography.Entry
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.Store

  setup do
    {:ok, db} = Store.open_memory()
    on_exit(fn -> Store.close(db) end)
    {:ok, db: db}
  end

  defp insert(db, session_id, type, payload) do
    {:ok, _id} = Store.insert(db, EventRecord.new(session_id, type, payload))
    :ok
  end

  defp edit(db, session_id, path, opts) do
    insert(db, session_id, :file_edit_proposed, %{
      "path" => path,
      "before_content" => Keyword.get(opts, :before, ""),
      "after_content" => Keyword.fetch!(opts, :after),
      "tool_call_id" => Keyword.get(opts, :tool_call_id, "tc"),
      "tool_name" => Keyword.get(opts, :tool_name, "apply_diff")
    })
  end

  test "for_line attributes a line to the turn that introduced it", %{db: db} do
    insert(db, "s1", :user_message, %{"text" => "add auth handling"})
    insert(db, "s1", :thinking_delta, %{"delta" => "I'll use "})
    insert(db, "s1", :thinking_delta, %{"delta" => "middleware"})
    insert(db, "s1", :assistant_delta, %{"delta" => "Adding an auth middleware."})

    edit(db, "s1", "/proj/router.ex",
      before: "",
      after: "def handle, do: :auth",
      tool_call_id: "tc1"
    )

    assert {:ok, %Entry{} = entry} =
             Autobiography.for_line("/proj/router.ex", "def handle", db: db)

    assert entry.session_id == "s1"
    assert entry.tool_call_id == "tc1"
    assert entry.user_request == "add auth handling"
    assert entry.thinking == "I'll use middleware"
    assert entry.assistant_text == "Adding an auth middleware."
  end

  test "for_line prefers the edit that introduced the text over one that only contains it", %{
    db: db
  } do
    # Older edit already contains the line (so it didn't introduce it).
    edit(db, "s1", "/p/a.ex", before: "x = 1", after: "x = 1\nkeep = true", tool_call_id: "old")
    # Newer edit introduces a different line.
    edit(db, "s1", "/p/a.ex",
      before: "x = 1\nkeep = true",
      after: "x = 1\nkeep = true\nnew = 2",
      tool_call_id: "new"
    )

    assert {:ok, %Entry{tool_call_id: "new"}} =
             Autobiography.for_line("/p/a.ex", "new = 2", db: db)

    # "keep = true" was present-before in the newer edit, so attribution lands on the introducer.
    assert {:ok, %Entry{tool_call_id: "old"}} =
             Autobiography.for_line("/p/a.ex", "keep = true", db: db)
  end

  test "for_line returns nil when the agent never wrote the line", %{db: db} do
    edit(db, "s1", "/p/a.ex", after: "alpha")
    assert {:ok, nil} = Autobiography.for_line("/p/a.ex", "beta", db: db)
    assert {:ok, nil} = Autobiography.for_line("/p/other.ex", "alpha", db: db)
  end

  test "for_file lists distinct edit-turns most recent first", %{db: db} do
    edit(db, "s1", "/p/a.ex", after: "one", tool_call_id: "t1")
    edit(db, "s1", "/p/a.ex", after: "one\ntwo", tool_call_id: "t2")
    # Same tool_call_id collapses to one turn even if it emitted two edits.
    edit(db, "s2", "/p/a.ex", after: "one\ntwo\nthree", tool_call_id: "t3")
    edit(db, "s2", "/p/a.ex", after: "one\ntwo\nthree\nthree2", tool_call_id: "t3")

    assert {:ok, entries} = Autobiography.for_file("/p/a.ex", db: db)
    assert Enum.map(entries, & &1.tool_call_id) == ["t3", "t2", "t1"]
  end

  test "falls back to basename match when the exact path differs", %{db: db} do
    # Agent stored a project-relative path; caller asks with an absolute one.
    edit(db, "s1", "lib/router.ex", after: "def handle, do: :ok")

    assert {:ok, %Entry{path: "lib/router.ex"}} =
             Autobiography.for_line("/home/me/proj/lib/router.ex", "def handle", db: db)
  end
end
