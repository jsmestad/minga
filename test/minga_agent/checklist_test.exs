defmodule MingaAgent.ChecklistTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Checklist
  alias MingaAgent.Tool.Output.Reference

  test "replacement preserves task identities and order after encoding and rejects stale updates" do
    {:ok, token} = Reference.token("session-one", String.duplicate("a", 32))

    {:ok, retained} =
      Reference.new(
        token: token,
        media_type: "text/plain",
        bytes: 2,
        sha256: Reference.digest("ok")
      )

    pending = %{"id" => "build", "description" => "Run the build"}

    done =
      Map.merge(pending, %{
        "status" => "done",
        "note" => "Build exited zero",
        "result_ref" => retained
      })

    blocked = %{
      "id" => "review",
      "description" => "Review changes",
      "status" => "blocked",
      "note" => "Waiting for approval"
    }

    active = %{"id" => "draft", "description" => "Write notes", "status" => "in_progress"}

    assert {:ok, first} = Checklist.replace(Checklist.new(), 0, [pending, blocked])
    assert {:ok, updated} = Checklist.replace(first, 1, [blocked, done, active])
    assert {:ok, restored} = Checklist.decode(Checklist.encode(updated))
    assert {2, [review, build, draft]} = Checklist.snapshot(restored)
    assert {review.id, review.status, review.note} == {"review", :blocked, "Waiting for approval"}
    assert {build.id, build.status, build.result_ref} == {"build", :done, retained}
    assert {draft.id, draft.status} == {"draft", :in_progress}
    assert {:error, {:stale_revision, 2}} = Checklist.replace(restored, 1, [])
    assert {:ok, cleared} = Checklist.replace(restored, 2, [])
    assert Checklist.snapshot(cleared) == {3, []}
  end

  test "rejects duplicate identities, malformed facts, and oversized replacements" do
    task = %{"id" => "id", "description" => "Task"}
    too_many = Enum.map(1..101, &%{task | "id" => Integer.to_string(&1)})

    for items <- [
          [task, task],
          [Map.put(task, "status", "unknown")],
          [Map.put(task, "result_ref", "/tmp/output")],
          [Map.put(task, "note", String.duplicate("x", 2_049))],
          too_many
        ] do
      assert {:error, :invalid_checklist} = Checklist.replace(Checklist.new(), 0, items)
    end
  end
end
