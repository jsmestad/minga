defmodule MingaAgent.Session.PrefixTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelSelection
  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.ContinuationCodec
  alias MingaAgent.Session.Outcome
  alias MingaAgent.Session.PrefixStore
  alias MingaAgent.Session.Request
  alias MingaAgent.Test.ModelSelectionFixture
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  defp identity do
    selection =
      ModelSelectionFixture.selection(request_provider: :openai_codex, model_id: "gpt-6.1-sol")

    ModelSelection.replay_identity(
      selection,
      %{kind: :oauth, account_id: "fixture-account", source_id: String.duplicate("a", 64)}
    )
  end

  defp schema(name, options \\ %{}) do
    %{
      name: name,
      description: "Inspect a project value",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{"mode" => %{"enum" => ["brief", "full"]}}
      },
      strict: false,
      provider_options: options,
      source: :config
    }
  end

  defp candidate(instructions \\ "selected instructions", schemas \\ [schema("inspect")]) do
    {:ok, candidate} = PrefixStore.candidate(instructions, schemas, identity())
    candidate
  end

  defp completed(prefix) do
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), prefix)
    {:ok, request, active} = Continuation.begin_request(initial, "request-1", 1, "first")
    outcome = Outcome.new(request, request.messages ++ [Context.assistant("answer")])
    {:ok, continuation} = Continuation.complete(active, outcome, 2)
    {request, continuation}
  end

  test "declarations have deterministic names and object ordering without changing meaningful arrays" do
    first =
      candidate("instructions", [schema("zeta"), schema("alpha", %{namespace: "workspace"})])

    second =
      candidate("instructions", [schema("alpha", %{namespace: "workspace"}), schema("zeta")])

    assert first == second
    assert Enum.map(first.schemas, & &1.name) == ["alpha", "zeta"]

    assert get_in(hd(first.schemas), [:parameter_schema, "properties", "mode", "enum"]) == [
             "brief",
             "full"
           ]

    assert {:error, :invalid_prefix_candidate} =
             PrefixStore.candidate("instructions", [schema("same"), schema("same")], identity())

    assert {:error, :invalid_prefix_candidate} =
             PrefixStore.candidate("instructions", [:invalid], identity())

    refute candidate("instructions", [schema("alpha", %{namespace: "other"})]).schemas_id ==
             first.schemas_id
  end

  test "requests and outcomes freeze the admitted epoch and reject stale epoch evidence" do
    original = candidate()
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), original)
    {:ok, request, active} = Continuation.begin_request(initial, "request", 1, "inspect")
    assert request.epoch_id == original.epoch_id
    assert request.prefix == original
    assert hd(request.messages) == Context.system(original.instructions)
    changed = candidate("different instructions")
    assert {:error, :request_active} = Continuation.change_prefix(active, changed)

    wrong_request =
      Request.new(
        request.request_id,
        request.turn_id,
        request.conversation_revision,
        request.messages,
        changed
      )

    wrong = Outcome.new(wrong_request, request.messages ++ [Context.assistant("answer")])
    assert {:error, :stale_outcome} = Continuation.complete(active, wrong, 2)
    assert active.active_request == request
  end

  test "every idle or busy transition has an explicit result and preserves last-good values" do
    original = candidate()
    changed = candidate("new skill instructions")
    {request, idle} = completed(original)
    assert {:ok, :unchanged, ^idle} = Continuation.change_prefix(idle, original)

    assert {:error, {:portable_context_transition_required, transition}} =
             Continuation.change_prefix(idle, changed)

    assert transition.actions == [:cancel_retain, :new_session]
    assert idle.messages == request.messages ++ [Context.assistant("answer")]
    assert map_size(idle.prefixes.epochs) == 1

    assert {:error, {:portable_context_transition_required, _}} =
             Continuation.check_model_change(idle, "ms2_other")

    {:ok, next, active} = Continuation.begin_request(idle, "request-2", 3, "inspect again")

    assistant = %Message{
      role: :assistant,
      tool_calls: [ReqLLM.ToolCall.new("call", "inspect", "{}")]
    }

    {:ok, _checkpoint, checkpointed} =
      Continuation.checkpoint_tool_group(active, next.request_id, next.messages ++ [assistant], [
        %{tool_call_id: "call", name: "inspect", arguments: %{}}
      ])

    assert {:error, :request_active} = Continuation.change_prefix(checkpointed, changed)
    unsettled = Continuation.cancel(checkpointed)

    assert {:error, :effect_reconciliation_required} =
             Continuation.change_prefix(unsettled, changed)

    assert checkpointed.tool_checkpoint.epoch_id == original.epoch_id
  end

  test "a skill preview before any dispatched history can replace only the initial prefix" do
    original = candidate()
    changed = candidate("selected skill")
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), original)
    assert {:ok, :applied, selected} = Continuation.change_prefix(initial, changed)
    assert selected.messages == [Context.system("selected skill")]
    assert map_size(selected.prefixes.instructions) == 1
    assert map_size(selected.prefixes.schemas) == 1
    assert map_size(selected.prefixes.epochs) == 1
  end

  test "component interning retains historical roots without a predecessor chain" do
    first = candidate("first skill")
    second = candidate("second skill")
    store = PrefixStore.new() |> PrefixStore.select(first) |> PrefixStore.select(second)
    assert map_size(store.instructions) == 2
    assert map_size(store.schemas) == 1
    retained = PrefixStore.retain(store, [first.epoch_id])
    assert PrefixStore.resolve(retained, first.epoch_id) == first
    pruned = PrefixStore.retain(retained, [])
    assert map_size(pruned.epochs) == 1
    assert map_size(pruned.instructions) == 1
    assert PrefixStore.resolve(pruned, second.epoch_id) == second
  end

  test "branch selection restores the historical epoch along with its exact native values" do
    first = candidate("first skill")
    second = candidate("second skill")
    store = PrefixStore.new() |> PrefixStore.select(first) |> PrefixStore.select(second)

    opaque =
      Context.assistant([
        ContentPart.provider_block(:openai, %{
          "type" => "reasoning",
          "encrypted_content" => "opaque"
        })
      ])

    messages = [
      Context.system(first.instructions),
      Context.user("first"),
      opaque,
      Context.user("second"),
      Context.assistant("second answer")
    ]

    boundaries = [
      %{transcript_id: 3, message_count: 3, revision: 1, epoch_id: first.epoch_id},
      %{transcript_id: 5, message_count: 5, revision: 2, epoch_id: second.epoch_id}
    ]

    {:ok, history} =
      Continuation.restore(messages, 2, 2, boundaries, %{}, :lossless, nil, prefixes: store)

    {:ok, early} = Continuation.branch_at(history, "original", 3)
    assert early.prefixes.selected == first.epoch_id
    assert early.messages == Enum.take(messages, 3)
    {:ok, restored} = early |> ContinuationCodec.encode() |> ContinuationCodec.decode()
    {:ok, original} = Continuation.switch_branch(restored, "original")
    assert original.prefixes.selected == second.epoch_id
    assert original.messages == messages
  end

  test "native compaction windows retain their epoch and are never repaired by prepending instructions" do
    prefix = candidate()
    {_request, history} = completed(prefix)
    window = [Context.user("canonical window"), Context.assistant("provider boundary")]
    {:ok, compacted} = Continuation.replace_messages(history, window)
    {:ok, :unchanged, compacted} = Continuation.change_prefix(compacted, prefix)

    {:ok, next, _active} =
      Continuation.begin_request(compacted, "after-compaction", 3, "continue")

    assert next.messages == window ++ [Context.user("continue")]
    assert next.epoch_id == prefix.epoch_id
    assert next.prefix.instructions == prefix.instructions
    assert hd(compacted.boundaries).epoch_id == prefix.epoch_id
  end

  test "v2 and v3 reads preserve opaque values and explicitly lack historical prefix proof" do
    opaque =
      Context.assistant([
        ContentPart.provider_block(:anthropic, %{
          "type" => "redacted_thinking",
          "data" => "opaque"
        })
      ])

    messages = [Context.system("historical instructions"), Context.user("question"), opaque]
    {:ok, historical} = Continuation.restore(messages, 1, 1, [], %{}, :lossless)

    for version <- [2, 3] do
      encoded =
        historical
        |> ContinuationCodec.encode()
        |> Map.put("version", version)
        |> Map.delete("prefixes")

      assert {:ok, restored} = ContinuationCodec.decode(encoded)
      assert restored.messages == messages
      assert restored.prefixes.selected == :unknown

      assert {:error,
              {:portable_context_transition_required, %{reason: :historical_identity_unknown}}} =
               Continuation.change_prefix(restored, candidate("historical instructions"))
    end
  end

  test "current codecs reject digest mismatches, missing identities, and dangling epoch references" do
    {_request, history} = completed(candidate())
    encoded = ContinuationCodec.encode(history)
    assert encoded["version"] == 4
    assert {:ok, restored} = ContinuationCodec.decode(encoded)
    assert restored.messages == history.messages
    assert restored.prefixes == history.prefixes
    assert {:error, _} = ContinuationCodec.decode(Map.delete(encoded, "prefixes"))
    [boundary] = encoded["boundaries"]
    dangling = Map.put(boundary, "epoch_id", %{"$" => "string", "value" => "px1_dangling"})

    assert {:error, :dangling_prefix_epoch} =
             ContinuationCodec.decode(Map.put(encoded, "boundaries", [dangling]))

    data = PrefixStore.dump(history.prefixes)
    [id] = Map.keys(data.instructions)

    assert {:error, :invalid_prefix_store} =
             PrefixStore.restore(%{data | instructions: %{id => "tampered"}})
  end

  test "empty native windows retain historical identity and cannot acquire a replacement prefix" do
    prefix = candidate()
    {_request, history} = completed(prefix)
    {:ok, compacted} = Continuation.replace_messages(history, [])
    assert {:ok, :unchanged, ^compacted} = Continuation.change_prefix(compacted, prefix)

    assert {:error, {:portable_context_transition_required, _}} =
             Continuation.change_prefix(compacted, candidate("changed"))

    assert {:ok, next, _active} = Continuation.begin_request(compacted, "empty-window", 3, "next")
    assert next.messages == [Context.user("next")]
    assert next.epoch_id == prefix.epoch_id
  end

  test "initial replacement retains branch roots and restore drops unreachable components" do
    first = candidate("first")
    second = candidate("second")
    abandoned = candidate("abandoned")
    store = PrefixStore.new() |> PrefixStore.select(abandoned) |> PrefixStore.select(first)

    branches = %{
      "saved" => %{
        messages: [Context.system(first.instructions), Context.user("saved")],
        boundaries: [],
        epoch_id: first.epoch_id
      }
    }

    {:ok, initial} =
      Continuation.restore(
        [Context.system(first.instructions)],
        0,
        0,
        [],
        branches,
        :lossless,
        nil,
        prefixes: store
      )

    assert map_size(initial.prefixes.epochs) == 1
    {:ok, :applied, changed} = Continuation.change_prefix(initial, second)
    assert map_size(changed.prefixes.epochs) == 2
    assert map_size(changed.prefixes.schemas) == 1
    assert {:ok, restored} = changed |> ContinuationCodec.encode() |> ContinuationCodec.decode()
    assert {:ok, branch} = Continuation.switch_branch(restored, "saved")
    assert branch.prefixes.selected == first.epoch_id
    assert branch.messages == branches["saved"].messages
  end

  test "malformed current branch structures and extra prefix store fields reject without raising" do
    {_request, history} = completed(candidate())
    encoded = ContinuationCodec.encode(history)

    for branches <- [nil, [], %{"bad" => nil}, %{"bad" => %{"boundaries" => :invalid}}] do
      assert {:error, _reason} = ContinuationCodec.decode(Map.put(encoded, "branches", branches))
    end

    assert {:error, :invalid_prefix_store} =
             history.prefixes
             |> PrefixStore.dump()
             |> Map.put(:unexpected, true)
             |> PrefixStore.restore()
  end

  test "known epochs cannot be rebound to a different active request or branch boundary" do
    first = candidate("first")
    second = candidate("second")
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), first)
    {:ok, request, active} = Continuation.begin_request(initial, "active", 1, "question")
    mixed = active.prefixes |> PrefixStore.select(second)

    assert {:error, :inconsistent_prefix_epoch} =
             Continuation.restore(
               active.messages,
               active.revision,
               active.durable_revision,
               [],
               %{},
               :lossless,
               nil,
               active_request: request,
               prefixes: mixed
             )

    {_request, history} = completed(first)

    branches = %{
      "wrong" => %{
        messages: history.messages,
        boundaries: history.boundaries,
        epoch_id: second.epoch_id
      }
    }

    mixed = mixed |> PrefixStore.select_epoch(first.epoch_id)

    assert {:error, :inconsistent_prefix_epoch} =
             Continuation.restore(
               history.messages,
               history.revision,
               history.durable_revision,
               history.boundaries,
               branches,
               :lossless,
               nil,
               prefixes: mixed
             )
  end

  test "selected skill names survive codec restore without reconstructing them from prompt text" do
    assert {:ok, prefix} =
             PrefixStore.candidate(
               :unknown,
               "immutable instruction text",
               [schema("inspect")],
               identity(),
               ["second", "first"]
             )

    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), prefix)
    assert {:ok, restored} = initial |> ContinuationCodec.encode() |> ContinuationCodec.decode()
    selected = PrefixStore.resolve(restored.prefixes, restored.prefixes.selected)
    assert selected.skills == ["second", "first"]
    assert selected.instructions == "immutable instruction text"

    assert {:error, :invalid_prefix_candidate} =
             PrefixStore.candidate(prefix, prefix.instructions, prefix.schemas, prefix.identity, [
               "first",
               "first"
             ])
  end

  test "malformed current selection and authentication identifiers never become prefix evidence" do
    valid = identity()

    invalid = [
      %{valid | selection_id: "ms2_" <> String.duplicate("!", 43)},
      %{valid | authentication: %{kind: :api_key, runtime_binding: String.duplicate("!", 32)}},
      %{
        valid
        | authentication: %{
            kind: :oauth,
            account_id: "fixture",
            source_id: String.duplicate("z", 64)
          }
      }
    ]

    for identity <- invalid do
      assert {:error, :invalid_prefix_candidate} =
               PrefixStore.candidate("instructions", [], identity)
    end
  end

  test "one thousand unchanged turns and reloads add no prefix snapshots or encoded schema bytes" do
    prefix = candidate()
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), prefix)
    initial_bytes = byte_size(JSON.encode!(ContinuationCodec.encode(initial)["prefixes"]))

    history =
      Enum.reduce(1..1000, initial, fn turn, history ->
        {:ok, same} =
          PrefixStore.candidate(
            prefix,
            prefix.instructions,
            Enum.reverse(prefix.schemas),
            prefix.identity
          )

        {:ok, :unchanged, history} = Continuation.change_prefix(history, same)

        {:ok, request, active} =
          Continuation.begin_request(history, "request-#{turn}", turn * 2, "next")

        outcome = Outcome.new(request, request.messages ++ [Context.assistant("answer")])
        {:ok, completed} = Continuation.complete(active, outcome, turn * 2 + 1)
        completed
      end)

    assert history.prefixes == initial.prefixes
    assert byte_size(JSON.encode!(ContinuationCodec.encode(history)["prefixes"])) == initial_bytes
  end
end
