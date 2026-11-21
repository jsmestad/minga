defmodule MingaAgent.Session.PrefixTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Policy.{Limits, RequestCapacity}
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

  test "a superseded assessment cannot authorize a retry and refusal cannot retry unchanged" do
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), candidate())
    {:ok, request, active} = Continuation.begin_request(initial, "request", 1, "question")

    assert {:error, :stale_dispatch} =
             Continuation.begin_dispatch(active, "other", :initial, [], self())

    assert {:ok, first, messages, assessing} =
             Continuation.begin_dispatch(active, "request", :initial, [], self())

    assert messages == request.messages

    assert {:ok, retry, ^messages, retrying} =
             Continuation.begin_dispatch(assessing, "request", :initial, [], self())

    {:ok, limits} = Limits.new(%{input: nil, context: nil, output: nil, request_output: 16})
    fits = RequestCapacity.assess(limits, {:provider_count, 30}, {:encoded, 16}, 100)
    digest = :crypto.hash(:sha256, "synthetic prepared body")

    assert {:error, :stale_dispatch} = Continuation.assess_dispatch(retrying, first, digest, fits)
    assert {:ok, admitted} = Continuation.assess_dispatch(retrying, retry, digest, fits)
    assert {:error, :stale_dispatch} = Continuation.assess_dispatch(admitted, retry, digest, fits)

    too_large = RequestCapacity.assess(limits, {:provider_count, 96}, {:encoded, 16}, 100)
    assert {:ok, refused} = Continuation.assess_dispatch(retrying, retry, digest, too_large)

    assert {:error, :assessment_refused} =
             Continuation.begin_dispatch(refused, "request", :initial, [], self())

    assert {:ok, reopened} = refused |> ContinuationCodec.encode() |> ContinuationCodec.decode()
    assert {:error, :stale_dispatch} = Continuation.assess_dispatch(reopened, retry, digest, fits)
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
    assert {:error, :request_active} = Continuation.change_model_prefix(checkpointed, changed)
    unsettled = Continuation.cancel(checkpointed)

    assert {:error, :effect_reconciliation_required} =
             Continuation.change_prefix(unsettled, changed)

    assert {:error, :effect_reconciliation_required} =
             Continuation.change_model_prefix(unsettled, changed)

    assert checkpointed.tool_checkpoint.epoch_id == original.epoch_id
  end

  test "official Codex selections qualify by transport while model and endpoint identities remain distinct" do
    authentication = identity().authentication

    identities =
      for model_id <- ["gpt-6.1-sol", "gpt-5.6-luna", "gpt-5.6-terra"] do
        selection =
          ModelSelectionFixture.selection(request_provider: :openai_codex, model_id: model_id)

        selected = ModelSelection.replay_identity(selection, authentication)
        assert selected.native_contract == :codex_responses_exact_prefix_v1
        selected
      end

    assert identities |> Enum.map(& &1.selection_id) |> Enum.uniq() |> length() == 3

    for changed <- [
          [provider_model_id: "different-model"],
          [base_url: "http://chatgpt.com/backend-api"],
          [base_url: "https://chatgpt.com.invalid/backend-api"],
          [base_url: "https://custom.example/backend-api"]
        ] do
      selection =
        ModelSelectionFixture.selection(
          [request_provider: :openai_codex, model_id: "gpt-5.6-luna"] ++ changed
        )

      assert ModelSelection.replay_identity(selection, authentication).native_contract == :unknown
    end
  end

  test "classifier-only requalification retains captured epochs and refuses every changed input" do
    current = candidate()
    captured_identity = Map.put(current.identity, :native_contract, :unknown)

    assert {:ok, captured} =
             PrefixStore.candidate(
               :unknown,
               current.instructions,
               current.schemas,
               captured_identity,
               current.skills
             )

    {_request, history} = completed(captured)
    assert {:ok, restored} = history |> ContinuationCodec.encode() |> ContinuationCodec.decode()
    assert {:ok, :unchanged, ^restored} = Continuation.change_prefix(restored, current)
    assert PrefixStore.resolve(restored.prefixes, restored.prefixes.selected) == captured
    assert {:ok, :unchanged, ^restored} = Continuation.change_prefix(restored, captured)

    assert {:ok, request, active} =
             Continuation.begin_request(restored, "qualified-second", 3, "second")

    assert request.epoch_id == captured.epoch_id
    assert request.prefix == captured
    assert request.messages == history.messages ++ [Context.user("second")]
    assert {:error, :request_active} = Continuation.change_prefix(active, current)

    changed_authentication =
      Map.put(current.identity.authentication, :account_id, "another-account")

    different_selection =
      ModelSelectionFixture.selection(request_provider: :openai_codex, model_id: "gpt-5.6-luna")

    different_identity =
      ModelSelection.replay_identity(different_selection, current.identity.authentication)

    for {instructions, schemas, replay_identity, skills} <- [
          {"changed instructions", current.schemas, current.identity, current.skills},
          {current.instructions, [schema("changed")], current.identity, current.skills},
          {current.instructions, current.schemas, current.identity, ["changed-skill"]},
          {current.instructions, current.schemas,
           Map.put(current.identity, :authentication, changed_authentication), current.skills},
          {current.instructions, current.schemas, different_identity, current.skills}
        ] do
      assert {:ok, changed} =
               PrefixStore.candidate(:unknown, instructions, schemas, replay_identity, skills)

      assert {:error, {:portable_context_transition_required, _}} =
               Continuation.change_prefix(restored, changed)
    end
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

  test "restore rejects out-of-order schema names even when the stored digest matches" do
    data = PrefixStore.dump(PrefixStore.new())
    alpha = schema("alpha")
    zeta = schema("zeta")

    restore = fn schemas ->
      encoded = :erlang.term_to_binary({1, :schemas, schemas}, [:deterministic])
      id = "px1_" <> Base.url_encode64(:crypto.hash(:sha256, encoded), padding: false)
      PrefixStore.restore(%{data | schemas: %{id => schemas}})
    end

    assert {:ok, _store} = restore.([alpha, zeta])
    assert {:error, :invalid_prefix_store} = restore.([zeta, alpha])
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

  test "current epoch preflight checks top-level shape and epoch fields before the prefix store" do
    encoded = Continuation.new() |> ContinuationCodec.encode() |> Map.put("prefixes", nil)
    assert {:error, :invalid_prefix_store} = ContinuationCodec.decode(encoded)

    for {field, value} <- [{"boundaries", nil}, {"branches", nil}, {"branches", []}] do
      malformed = encoded |> Map.put(field, value) |> Map.put("active_request", %{})
      assert {:error, :invalid_prefix_epoch_structure} = ContinuationCodec.decode(malformed)
    end

    branch = %{"epoch_id" => nil, "boundaries" => []}

    for {field, value} <- [
          {"active_request", %{}},
          {"tool_checkpoint", %{}},
          {"boundaries", [%{}]},
          {"branches", %{"bad" => nil}},
          {"branches", %{"bad" => Map.put(branch, "boundaries", nil)}},
          {"branches", %{"bad" => Map.delete(branch, "epoch_id")}},
          {"branches", %{"bad" => Map.put(branch, "boundaries", [%{}])}}
        ] do
      assert {:error, :missing_prefix_epoch} =
               encoded |> Map.put(field, value) |> ContinuationCodec.decode()
    end
  end

  test "nil boundaries pass the epoch preflight and fail boundary decoding" do
    encoded = ContinuationCodec.encode(Continuation.new())
    branch = %{"messages" => [], "boundaries" => [nil], "epoch_id" => nil}

    for {field, value} <- [{"boundaries", [nil]}, {"branches", %{"saved" => branch}}] do
      malformed = Map.put(encoded, field, value)

      assert {:error, :invalid_prefix_store} =
               malformed |> Map.put("prefixes", nil) |> ContinuationCodec.decode()

      assert {:error, :invalid_continuation_boundary} = ContinuationCodec.decode(malformed)
    end
  end

  test "extra prefix store fields reject without raising" do
    {_request, history} = completed(candidate())

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

  test "model handoff retains branch snapshots and can reopen before another prompt" do
    first = candidate()
    {_request, history} = completed(first)
    {:ok, branched} = Continuation.branch_at(history, "original", 2)

    selection =
      ModelSelectionFixture.selection(request_provider: :openai_codex, model_id: "other-model")

    identity = ModelSelection.replay_identity(selection, first.identity.authentication)
    {:ok, target} = PrefixStore.candidate("target instructions", first.schemas, identity)

    assert {:ok, :applied, switched} = Continuation.change_model_prefix(branched, target)

    assert switched.messages == [
             Context.system("target instructions"),
             Context.user("first"),
             Context.assistant("answer")
           ]

    assert {:ok, reopened} = switched |> ContinuationCodec.encode() |> ContinuationCodec.decode()

    assert {:ok, next, _active} =
             Continuation.begin_request(reopened, "after-switch", 3, "continue")

    assert next.prefix == target
    assert next.messages == switched.messages ++ [Context.user("continue")]
    assert {:ok, historical} = Continuation.switch_branch(reopened, "original")
    assert historical.messages == history.messages
    assert historical.prefixes.selected == first.epoch_id
    assert {:ok, converted_branch} = Continuation.branch_at(reopened, "converted", 2)
    assert converted_branch.messages == switched.messages
    assert converted_branch.prefixes.selected == target.epoch_id
  end

  test "reasoning-only boundaries remain branchable after model handoff" do
    first = candidate()
    {_request, history} = completed(first)
    {:ok, request, active} = Continuation.begin_request(history, "thinking-only", 3, "think")
    thinking = %Message{role: :assistant, content: [ContentPart.thinking("private reasoning")]}
    outcome = Outcome.new(request, request.messages ++ [thinking])
    {:ok, completed} = Continuation.complete(active, outcome, 4)

    assert {:ok, :applied, switched} =
             Continuation.change_model_prefix(completed, candidate("next"))

    assert {:ok, restored} = switched |> ContinuationCodec.encode() |> ContinuationCodec.decode()
    assert {:ok, branch} = Continuation.branch_at(restored, "thinking", 4)
    assert List.last(branch.messages) == Context.user("think")
  end

  test "file references cannot inherit a replacement key or account through model selection" do
    first = candidate()
    {:ok, :applied, initial} = Continuation.change_prefix(Continuation.new(), first)
    file = ContentPart.owned_file_id("private-file", :openai)
    {:ok, request, active} = Continuation.begin_request(initial, "file", 1, [file])

    {:ok, history} =
      Continuation.complete(
        active,
        Outcome.new(request, request.messages ++ [Context.assistant("read")]),
        2
      )

    {:ok, same_namespace} = PrefixStore.candidate("another model", first.schemas, first.identity)

    assert {:ok, :applied, _switched} =
             Continuation.change_model_prefix(history, same_namespace, :retain)

    changed_identity =
      put_in(first.identity, [:authentication, :account_id], "replacement-account")

    {:ok, different_namespace} =
      PrefixStore.candidate("another model", first.schemas, changed_identity)

    assert {:error, :unportable_attachment} =
             Continuation.change_model_prefix(history, different_namespace, :retain)
  end
end
