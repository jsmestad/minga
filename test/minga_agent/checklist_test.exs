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
    encoded = Checklist.encode(updated)
    assert {:ok, restored} = Checklist.decode(encoded)
    assert {2, [review, build, draft]} = Checklist.snapshot(restored)
    assert {review.id, review.status, review.note} == {"review", :blocked, "Waiting for approval"}
    assert {build.id, build.status, build.result_ref} == {"build", :done, retained}
    assert {draft.id, draft.status} == {"draft", :in_progress}

    assert %{"items" => [_, encoded_done, _]} = encoded
    assert {:error, :invalid_checklist} = Checklist.replace(restored, 2, [encoded_done])
    assert {:error, :invalid_checklist} = Checklist.decode(%{encoded | "items" => [done]})

    assert {:error, {:stale_revision, 2}} = Checklist.replace(restored, 1, [])
    assert {:ok, cleared} = Checklist.replace(restored, 2, [])
    assert Checklist.snapshot(cleared) == {3, []}
  end

  test "preserves original task text and accepts a multibyte note at the byte limit" do
    note = String.duplicate("é", 1_024)

    tasks = [
      %{"id" => "id", "description" => "Task", "note" => nil},
      %{"id" => " id ", "description" => " Task ", "note" => note}
    ]

    assert {:ok, checklist} = Checklist.replace(Checklist.new(), 0, tasks)
    assert {:ok, restored} = Checklist.decode(Checklist.encode(checklist))
    assert {1, [first, second]} = Checklist.snapshot(restored)

    assert {first.id, first.description, first.status, first.note} ==
             {"id", "Task", :pending, nil}

    assert {second.id, second.description, second.status, second.note} ==
             {" id ", " Task ", :pending, note}
  end

  test "both replacement and restoration reject duplicate identities and invalid facts" do
    task = %{"id" => "id", "description" => "Task"}
    too_many = Enum.map(1..101, &%{task | "id" => Integer.to_string(&1)})
    malformed_struct = Checklist.new() |> Map.put("id", "") |> Map.put("description", "Task")

    for items <- [
          [task, task],
          [malformed_struct],
          [Map.put(task, "status", "unknown")],
          [Map.put(task, "status", nil)],
          [Map.put(task, "description", " \t ")],
          [Map.put(task, "description", <<255>>)],
          [Map.put(task, "result_ref", "/tmp/output")],
          [Map.put(task, "note", String.duplicate("é", 1_025))],
          too_many
        ] do
      assert {:error, :invalid_checklist} = Checklist.replace(Checklist.new(), 0, items)

      assert {:error, :invalid_checklist} =
               Checklist.decode(%{"version" => 1, "revision" => 0, "items" => items})
    end
  end
end
