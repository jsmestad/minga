defmodule MingaAgent.SessionStoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.ArtifactStores
  alias MingaAgent.ArtifactSupervisor
  alias MingaAgent.Branch
  alias MingaAgent.ModelSelection
  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.ContinuationCodec
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Attachment
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference
  alias MingaAgent.Tool.Output.Revision
  alias MingaAgent.SessionStore
  alias MingaAgent.TranscriptEntry
  alias MingaAgent.ToolCall
  alias MingaAgent.TurnUsage
  alias ReqLLM.Context

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
      message_ids: [10, 20, 30, 40, 50, 60],
      pinned_ids: MapSet.new([20, 50]),
      usage: %TurnUsage{input: 100, output: 50, cache_read: 200, cache_write: 0, cost: 0.003},
      continuation: Continuation.new(),
      branches: [
        Branch.new(
          "branch-1",
          [TranscriptEntry.new(8, {:user, "branch prompt"})],
          ~U[2026-01-01 00:00:00Z]
        )
      ],
      memory: "- [2026-01-01 00:00 UTC] Use concise answers\n"
    }
  end

  # ── Save/Load round-trip ───────────────────────────────────────────────────

  describe "save and load round-trip" do
    test "saves and loads a session", %{tmp_dir: dir} do
      data = sample_data()
      assert :ok = SessionStore.save(data, dir)

      assert {:ok, loaded} = SessionStore.load(data.id, dir)
      assert loaded.id == data.id
      assert loaded.model_name == "claude-sonnet-4"
    end

    test "persists a versioned secret-free executable selection", %{tmp_dir: dir} do
      selection = model_selection()
      data = Map.put(sample_data("selected-route"), :model_selection, selection)

      assert :ok = SessionStore.save(data, dir)
      path = Path.join(SessionStore.sessions_dir(dir), "#{data.id}.json")
      raw = File.read!(path)
      record = JSON.decode!(raw)

      assert record["version"] == 5

      assert record["model_selection"]["credential"] == %{
               "kind" => "none",
               "provider" => "test"
             }

      refute Map.has_key?(record["model_selection"], "api_key")
      refute Map.has_key?(record["model_selection"], "access_token")

      assert {:ok, loaded} = SessionStore.load(data.id, dir)
      assert %ModelSelection.Stored{} = loaded.model_selection
      assert ModelSelection.id(loaded.model_selection) == ModelSelection.id(selection)
    end

    test "loads version two model strings as deterministic correction intent", %{tmp_dir: dir} do
      data = sample_data("version-two-selection")
      assert :ok = SessionStore.save(data, dir)

      path = Path.join(SessionStore.sessions_dir(dir), "#{data.id}.json")

      record =
        path
        |> File.read!()
        |> JSON.decode!()
        |> Map.put("version", 2)
        |> Map.delete("model_selection")
        |> Map.delete("selection_intent")
        |> Map.delete("artifact_generation")
        |> Map.update!("messages", &Enum.map(&1, fn message -> Map.delete(message, "output") end))

      File.write!(path, JSON.encode!(record))

      assert {:ok, loaded} = SessionStore.load(data.id, dir)
      assert loaded.model_selection == nil

      assert loaded.selection_intent == %{
               "model" => data.model_name,
               "provider" => data.provider_name
             }
    end

    test "version three and four executable snapshots retain their exact selection when upgraded",
         %{tmp_dir: dir} do
      resolve_opts = [
        config: MingaAgent.Test.ModelSelectionFixture.config(),
        backend_spec: MingaAgent.ProviderPacks.Native.spec(),
        credential_snapshot: MingaAgent.Credentials.Snapshot.new(%{}, nil, "http://127.0.0.1:1")
      ]

      {:ok, selection} = MingaAgent.ModelResolver.resolve("test:test-model", resolve_opts)

      for version <- [3, 4] do
        data = Map.put(sample_data("model-version-#{version}"), :model_selection, selection)
        assert :ok = SessionStore.save(data, dir)
        path = Path.join(SessionStore.sessions_dir(dir), "#{data.id}.json")

        legacy =
          path
          |> File.read!()
          |> JSON.decode!()
          |> Map.put("version", version)
          |> Map.delete("artifact_generation")
          |> Map.update!(
            "messages",
            &Enum.map(&1, fn message -> Map.delete(message, "output") end)
          )

        File.write!(path, JSON.encode!(legacy))

        assert {:ok, loaded} = SessionStore.load(data.id, dir)
        assert ModelSelection.id(loaded.model_selection) == ModelSelection.id(selection)

        assert {:ok, executable} =
                 MingaAgent.ModelResolver.restore(loaded.model_selection, resolve_opts)

        assert :ok = SessionStore.save(Map.put(loaded, :model_selection, executable), dir)
        assert {:ok, upgraded} = SessionStore.load(data.id, dir)
        assert ModelSelection.id(upgraded.model_selection) == ModelSelection.id(selection)
      end
    end

    test "persists the exact active request for restart recovery", %{tmp_dir: dir} do
      data = sample_data()

      assert {:ok, request, continuation} =
               Continuation.begin_request(data.continuation, "request-in-flight", 21, [
                 ReqLLM.Context.user("continue this exact prompt")
               ])

      assert :ok = SessionStore.save(%{data | continuation: continuation}, dir)
      assert {:ok, loaded} = SessionStore.load(data.id, dir)
      assert loaded.continuation.active_request == request
      assert loaded.continuation.active_request.messages == request.messages
    end

    test "rejects omitted and out-of-range continuation history fields" do
      encoded = ContinuationCodec.encode(Continuation.new())

      for field <- ["boundaries", "branches"] do
        assert {:error, :invalid_continuation} =
                 encoded |> Map.delete(field) |> ContinuationCodec.decode()
      end

      malformed_boundary = %{"transcript_id" => 1, "message_count" => 1, "revision" => 1}

      assert {:error, :invalid_continuation_boundaries} =
               encoded
               |> Map.put("boundaries", [malformed_boundary])
               |> ContinuationCodec.decode()
    end

    test "preserves user messages", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      {:ok, loaded} = SessionStore.load(data.id, dir)
      user_msgs = Enum.filter(loaded.messages, &match?({:user, _}, &1))
      assert [{:user, "Hello, how are you?"}] = user_msgs
    end

    test "preserves user message attachments", %{tmp_dir: dir} do
      data = %{
        sample_data()
        | messages: [{:user, "see image", [%{filename: "chart.png", size_kb: 42}]}],
          message_ids: [10],
          pinned_ids: MapSet.new()
      }

      SessionStore.save(data, dir)

      {:ok, loaded} = SessionStore.load(data.id, dir)
      assert loaded.messages == [{:user, "see image", [%{filename: "chart.png", size_kb: 42}]}]
    end

    test "preserves assistant messages", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      {:ok, loaded} = SessionStore.load(data.id, dir)
      assert {:assistant, "I'm doing great!"} in loaded.messages
    end

    test "preserves tool call messages", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      {:ok, loaded} = SessionStore.load(data.id, dir)
      tool_calls = Enum.filter(loaded.messages, &match?({:tool_call, _}, &1))
      assert [{:tool_call, tc}] = tool_calls
      assert tc.name == "read_file"
      assert tc.args == %{"path" => "lib/foo.ex"}
      assert tc.result == "defmodule Foo do\nend"
      assert tc.is_error == false
      assert tc.collapsed == true
      assert tc.duration_ms == 42
      assert tc.status == :complete
      assert tc.auto_approved_scope == :session
      assert tc.preview == nil
      assert tc.output == nil
    end

    test "round-trips complete and incomplete typed output without reclassifying legacy text", %{
      tmp_dir: dir
    } do
      {:ok, complete_range} = Range.new(:full, :bytes, 0, 4, 4)
      {:ok, complete_output} = Output.new("done", :complete, complete_range)
      {:ok, incomplete_range} = Range.new(:captured_prefix, :bytes, 0, 7, :unknown)

      {:ok, incomplete_output} =
        Output.new("partial", {:incomplete, :interrupted}, incomplete_range)

      complete_call =
        ToolCall.new("complete-output", "read_file")
        |> ToolCall.complete("done", complete_output)

      incomplete_call =
        ToolCall.new("incomplete-output", "shell")
        |> ToolCall.error("partial [truncated]", incomplete_output)

      data = %{
        sample_data("typed-output-roundtrip")
        | messages: [{:tool_call, complete_call}, {:tool_call, incomplete_call}],
          message_ids: [1, 2],
          pinned_ids: MapSet.new()
      }

      assert :ok = SessionStore.save(data, dir)
      assert {:ok, loaded} = SessionStore.load(data.id, dir)

      assert [
               {:tool_call, %ToolCall{result: "done", output: ^complete_output}},
               {:tool_call, %ToolCall{result: "partial [truncated]", output: ^incomplete_output}}
             ] = loaded.messages

      encoded =
        Path.join(SessionStore.sessions_dir(dir), "#{data.id}.json")
        |> File.read!()
        |> JSON.decode!()

      assert encoded["version"] == 5
      assert encoded["artifact_generation"] == Reference.digest("")
    end

    test "continuation codec preserves output facts and finds refs in frozen branches and checkpoints" do
      text_output = retained_text_output("text-checkpoint", "full retained text")
      image_output = retained_image_output("image-branch", "never serialize these PNG bytes")

      frozen_result =
        Context.tool_result_message("read_file", "frozen-call", "image available", %{
          output: image_output
        })

      assert {:ok, continuation} =
               Continuation.restore(
                 [],
                 0,
                 0,
                 [],
                 %{"inactive" => %{messages: [frozen_result], boundaries: []}},
                 :lossless
               )

      assert {:ok, request, continuation} =
               Continuation.begin_request(continuation, "request-output", 1, "inspect")

      assistant = %ReqLLM.Message{
        role: :assistant,
        content: [],
        metadata: %{},
        tool_calls: [ReqLLM.ToolCall.new("current-call", "read_file", ~s({"path":"a"}))]
      }

      assert {:ok, checkpoint_id, continuation} =
               Continuation.checkpoint_tool_group(
                 continuation,
                 request.request_id,
                 request.messages ++ [assistant],
                 [
                   %{
                     tool_call_id: "current-call",
                     name: "read_file",
                     arguments: %{"path" => "a"}
                   }
                 ]
               )

      assert {:ok, continuation} =
               Continuation.admit_tool_effect(
                 continuation,
                 request.request_id,
                 checkpoint_id,
                 "current-call",
                 "read_file",
                 %{"path" => "a"}
               )

      current_result =
        Context.tool_result_message("read_file", "current-call", text_output.view, %{
          output: text_output
        })

      assert {:ok, continuation} =
               Continuation.complete_tool_effect(
                 continuation,
                 request.request_id,
                 checkpoint_id,
                 "current-call",
                 current_result
               )

      encoded = ContinuationCodec.encode(continuation)
      json = JSON.encode!(encoded)

      actual_tokens =
        encoded |> ContinuationCodec.references() |> Enum.map(& &1.token) |> Enum.sort()

      [image_attachment] = image_output.attachments
      expected_tokens = Enum.sort([image_attachment.reference.token, text_output.reference.token])
      assert actual_tokens == expected_tokens

      refute json =~ "never serialize these PNG bytes"
      refute json =~ "payload_bytes"
      refute json =~ "#PID"

      assert {:ok, decoded} = ContinuationCodec.decode(JSON.decode!(json))
      assert decoded == continuation
    end

    test "rejects unknown legacy tool status instead of inventing a completion", %{tmp_dir: dir} do
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

      assert {:error, :legacy_import_required} = SessionStore.load("bad-atoms", dir)
      assert {:error, :invalid_session_record} = SessionStore.load_legacy("bad-atoms", dir)
    end

    test "rejects malformed preview payloads defensively", %{tmp_dir: dir} do
      sessions_dir = SessionStore.sessions_dir(dir)
      File.mkdir_p!(sessions_dir)

      base_payload = %{
        "id" => "bad-preview",
        "timestamp" => "2026-01-01T00:00:00Z",
        "model_name" => "test-model",
        "messages" => [
          %{
            "type" => "tool_call",
            "id" => "tc",
            "name" => "shell",
            "args" => %{"command" => "mix test"},
            "status" => "complete",
            "result" => "ok",
            "is_error" => false,
            "collapsed" => true,
            "auto_approved_scope" => "session",
            "duration_ms" => 10,
            "preview" => %{"kind" => "shell", "summary" => "mix test", "lines" => ["$ mix test"]}
          }
        ],
        "usage" => %{}
      }

      File.write!(Path.join(sessions_dir, "bad-preview-kind.json"), JSON.encode!(base_payload))

      {:ok, loaded_kind} = SessionStore.load_legacy("bad-preview-kind", dir)

      [{:tool_call, tool_call_kind}] = loaded_kind.messages
      assert tool_call_kind.preview == nil

      bad_lines_payload =
        put_in(base_payload, ["messages", Access.at(0), "preview"], %{
          "kind" => "diff",
          "summary" => "lib/foo.ex",
          "lines" => ["-old", 123]
        })

      File.write!(
        Path.join(sessions_dir, "bad-preview-lines.json"),
        JSON.encode!(bad_lines_payload)
      )

      {:ok, loaded_lines} = SessionStore.load_legacy("bad-preview-lines", dir)

      [{:tool_call, tool_call_lines}] = loaded_lines.messages
      assert tool_call_lines.preview == nil
    end

    test "preserves thinking messages", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      {:ok, loaded} = SessionStore.load(data.id, dir)
      thinking = Enum.filter(loaded.messages, &match?({:thinking, _, _}, &1))
      assert [{:thinking, "Let me think about this...", true}] = thinking
    end

    test "preserves system messages", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      {:ok, loaded} = SessionStore.load(data.id, dir)
      system = Enum.filter(loaded.messages, &match?({:system, _, _}, &1))
      assert [{:system, "Session started", :info}] = system
    end

    test "preserves usage messages", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      {:ok, loaded} = SessionStore.load(data.id, dir)
      usage = Enum.filter(loaded.messages, &match?({:usage, _}, &1))
      assert [{:usage, u}] = usage
      assert u.input == 100
      assert u.cost == 0.003
    end

    test "preserves total usage", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      {:ok, loaded} = SessionStore.load(data.id, dir)
      assert loaded.usage.input == 100
      assert loaded.usage.cost == 0.003
    end

    test "preserves resumable metadata, branches, and memory", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      {:ok, loaded} = SessionStore.load(data.id, dir)
      assert loaded.title == "Hello, how are you?"
      assert loaded.provider_name == "native"
      assert [%Branch{name: "branch-1"} = branch] = loaded.branches
      assert Branch.messages(branch) == [{:user, "branch prompt"}]
      assert Branch.entry_ids(branch) == [8]
      assert loaded.message_ids == [10, 20, 30, 40, 50, 60]
      assert loaded.pinned_ids == MapSet.new([20, 50])
      assert loaded.memory =~ "Use concise answers"
    end

    test "loads legacy branch snapshots that predate structural message IDs", %{tmp_dir: dir} do
      sessions_dir = SessionStore.sessions_dir(dir)
      File.mkdir_p!(sessions_dir)

      File.write!(
        Path.join(sessions_dir, "legacy-branch.json"),
        JSON.encode!(%{
          "id" => "legacy-branch",
          "timestamp" => "2026-01-01T00:00:00Z",
          "model_name" => "test-model",
          "messages" => [
            %{"type" => "user", "text" => "question"},
            %{"type" => "assistant", "text" => "answer"}
          ],
          "message_ids" => [1, 2],
          "pinned_ids" => [2],
          "branches" => [
            %{
              "name" => "old-shape",
              "messages" => [
                %{"type" => "user", "text" => "question"},
                %{"type" => "assistant", "text" => "answer"}
              ],
              "created_at" => "2026-01-01T00:00:00Z"
            }
          ],
          "usage" => %{}
        })
      )

      source = File.read!(Path.join(sessions_dir, "legacy-branch.json"))
      assert {:error, :legacy_import_required} = SessionStore.load("legacy-branch", dir)

      assert {:ok, %{branches: [branch], message_ids: [1, 2], pinned_ids: pinned_ids}} =
               SessionStore.load_legacy("legacy-branch", dir)

      assert File.read!(Path.join(sessions_dir, "legacy-branch.json")) == source

      assert Branch.messages(branch) == [{:user, "question"}, {:assistant, "answer"}]
      assert Branch.entry_ids(branch) == [1, 2]
      assert pinned_ids == MapSet.new([2])
    end

    test "version-one records require explicit legacy import", %{tmp_dir: dir} do
      sessions_dir = SessionStore.sessions_dir(dir)
      File.mkdir_p!(sessions_dir)
      path = Path.join(sessions_dir, "version-one.json")

      File.write!(
        path,
        JSON.encode!(%{
          "id" => "version-one",
          "version" => 1,
          "timestamp" => "2026-01-01T00:00:00Z",
          "model_name" => "test-model",
          "messages" => [%{"type" => "user", "text" => "question"}],
          "usage" => %{}
        })
      )

      assert {:error, :legacy_import_required} = SessionStore.load("version-one", dir)
      assert {:ok, imported} = SessionStore.load_legacy("version-one", dir)
      assert imported.continuation.provenance == :legacy_reconstructed
      assert {:ok, original} = JSON.decode(File.read!(path))
      assert original["version"] == 1

      assert [%{id: "version-one", continuation_kind: :legacy_import_required}] =
               SessionStore.list(dir)
    end

    test "legacy imports retain reconstructed provenance after being saved as version two", %{
      tmp_dir: dir
    } do
      sessions_dir = SessionStore.sessions_dir(dir)
      File.mkdir_p!(sessions_dir)

      File.write!(
        Path.join(sessions_dir, "legacy-provenance.json"),
        JSON.encode!(%{
          "id" => "legacy-provenance",
          "timestamp" => "2026-01-01T00:00:00Z",
          "model_name" => "test-model",
          "messages" => [%{"type" => "user", "text" => "question"}],
          "usage" => %{}
        })
      )

      assert {:ok, imported} = SessionStore.load_legacy("legacy-provenance", dir)
      assert imported.continuation.provenance == :legacy_reconstructed
      assert :ok = SessionStore.save(imported, dir)

      assert [%{id: "legacy-provenance", continuation_kind: :legacy_reconstructed}] =
               SessionStore.list(dir)
    end

    test "normalizes invalid persisted branch identity candidates without raising", %{
      tmp_dir: dir
    } do
      sessions_dir = SessionStore.sessions_dir(dir)
      File.mkdir_p!(sessions_dir)

      File.write!(
        Path.join(sessions_dir, "invalid-branch-ids.json"),
        JSON.encode!(%{
          "id" => "invalid-branch-ids",
          "timestamp" => "2026-01-01T00:00:00Z",
          "model_name" => "test-model",
          "messages" => [%{"type" => "user", "text" => "active"}],
          "message_ids" => [10],
          "branches" => [
            %{
              "name" => "invalid-identities",
              "messages" => [
                %{"type" => "user", "text" => "one"},
                %{"type" => "assistant", "text" => "two"},
                %{"type" => "user", "text" => "three"}
              ],
              "message_ids" => [0, "bad", 2],
              "created_at" => "2026-01-01T00:00:00Z"
            }
          ],
          "usage" => %{}
        })
      )

      assert {:ok, %{branches: [branch]}} =
               SessionStore.load_legacy("invalid-branch-ids", dir)

      assert Branch.entry_ids(branch) == [11, 12, 2]
      assert Branch.messages(branch) == [{:user, "one"}, {:assistant, "two"}, {:user, "three"}]
    end

    test "writes transcript and remote token files with private permissions", %{tmp_dir: dir} do
      data = sample_data("private-session")
      assert :ok = SessionStore.save(data, dir)

      assert {:ok, "remote-token"} =
               SessionStore.establish_remote_token(data.id, "remote-token", dir)

      sessions_dir = SessionStore.sessions_dir(dir)
      session_path = Path.join(sessions_dir, "private-session.json")
      token_dir = Path.join(sessions_dir, ".remote_tokens")
      token_path = Path.join(token_dir, "private-session.json")

      assert private_mode?(File.stat!(sessions_dir).mode, 0o077)
      assert private_mode?(File.stat!(session_path).mode, 0o077)
      assert private_mode?(File.stat!(token_dir).mode, 0o077)
      assert private_mode?(File.stat!(token_path).mode, 0o077)
    end

    test "rejects unknown session and continuation versions", %{tmp_dir: dir} do
      data = sample_data("future-version")
      assert :ok = SessionStore.save(data, dir)

      path = Path.join(SessionStore.sessions_dir(dir), "#{data.id}.json")
      record = path |> File.read!() |> JSON.decode!()

      File.write!(path, JSON.encode!(Map.put(record, "version", 99)))
      assert {:error, {:unknown_session_version, 99}} = SessionStore.load(data.id, dir)

      continuation = Map.put(record["continuation"], "version", 99)
      record = %{record | "continuation" => continuation}
      File.write!(path, JSON.encode!(record))

      assert {:error, {:unknown_continuation_version, 99}} = SessionStore.load(data.id, dir)
    end

    test "rejects unknown version-two message types and tool statuses", %{tmp_dir: dir} do
      malformed_records = [
        {"unknown-type",
         fn record -> put_in(record, ["messages", Access.at(0), "type"], "other") end},
        {"unknown-status",
         fn record -> put_in(record, ["messages", Access.at(3), "status"], "other") end}
      ]

      for {id, mutate} <- malformed_records do
        data = sample_data(id)
        assert :ok = SessionStore.save(data, dir)

        path = Path.join(SessionStore.sessions_dir(dir), "#{id}.json")
        record = path |> File.read!() |> JSON.decode!()
        File.write!(path, JSON.encode!(mutate.(record)))

        assert {:error, :invalid_session_record} = SessionStore.load(id, dir)
      end
    end

    test "malformed transcript projections return errors from both load paths", %{tmp_dir: dir} do
      data = sample_data("malformed-record")
      assert :ok = SessionStore.save(data, dir)

      path = Path.join(SessionStore.sessions_dir(dir), "#{data.id}.json")
      record = path |> File.read!() |> JSON.decode!()

      File.write!(path, JSON.encode!(Map.put(record, "messages", [nil])))
      assert {:error, :invalid_session_record} = SessionStore.load(data.id, dir)

      legacy_record = record |> Map.put("version", 1) |> Map.put("messages", [nil])
      File.write!(path, JSON.encode!(legacy_record))
      assert {:error, :invalid_session_record} = SessionStore.load_legacy(data.id, dir)
    end

    test "returns error for nonexistent session", %{tmp_dir: dir} do
      assert {:error, _} = SessionStore.load("nonexistent-id", dir)
    end

    test "returns error when the sessions directory cannot be created", %{tmp_dir: dir} do
      blocked_base = Path.join(dir, "not-a-directory")
      File.write!(blocked_base, "file blocks mkdir")

      assert {:error, _reason} = SessionStore.save(sample_data("blocked"), blocked_base)
    end
  end

  describe "remote token identity" do
    test "persists manager identity outside the transcript", %{tmp_dir: dir} do
      data = sample_data("separate-identity")

      assert {:ok, "stable-token"} =
               SessionStore.establish_remote_token(data.id, "stable-token", dir)

      assert :ok = SessionStore.save(data, dir)

      assert {:ok, "stable-token"} =
               SessionStore.establish_remote_token(data.id, "replacement-token", dir)

      assert {:ok, transcript} = SessionStore.load(data.id, dir)
      refute Map.has_key?(transcript, :remote_token)

      refute File.read!(Path.join(SessionStore.sessions_dir(dir), "#{data.id}.json")) =~
               "remote_token"
    end

    test "existing canonical identity wins over a new candidate", %{tmp_dir: dir} do
      session_id = "first-creator-wins"

      assert {:ok, "first-token"} =
               SessionStore.establish_remote_token(session_id, "first-token", dir)

      assert {:ok, "first-token"} =
               SessionStore.establish_remote_token(session_id, "second-token", dir)
    end

    test "migrates identity from a legacy transcript", %{tmp_dir: dir} do
      data = sample_data("legacy-identity")
      assert :ok = SessionStore.save(data, dir)

      path = Path.join(SessionStore.sessions_dir(dir), "#{data.id}.json")
      payload = path |> File.read!() |> JSON.decode!() |> Map.put("remote_token", "legacy-token")
      File.write!(path, JSON.encode!(payload))

      assert {:ok, "legacy-token"} =
               SessionStore.establish_remote_token(data.id, "candidate-token", dir)

      assert :ok = SessionStore.save(data, dir)
      refute File.read!(path) =~ "remote_token"

      assert {:ok, "legacy-token"} =
               SessionStore.establish_remote_token(data.id, "replacement-token", dir)
    end

    test "concurrent transcript and identity writes preserve both owners", %{tmp_dir: dir} do
      data = sample_data("concurrent-identity")
      parent = self()

      transcript_task =
        Task.async(fn ->
          send(parent, {:writer_ready, self()})
          receive do: (:write -> SessionStore.save(data, dir))
        end)

      token_task =
        Task.async(fn ->
          send(parent, {:writer_ready, self()})

          receive do
            :write ->
              SessionStore.establish_remote_token(data.id, "concurrent-token", dir)
          end
        end)

      writer_pids =
        for _ <- 1..2 do
          assert_receive {:writer_ready, pid}
          pid
        end

      Enum.each(writer_pids, &send(&1, :write))
      assert :ok = Task.await(transcript_task)
      assert {:ok, "concurrent-token"} = Task.await(token_task)

      assert {:ok, transcript} = SessionStore.load(data.id, dir)
      assert transcript.messages == data.messages
      refute Map.has_key?(transcript, :remote_token)

      assert {:ok, "concurrent-token"} =
               SessionStore.establish_remote_token(data.id, "replacement-token", dir)
    end

    test "failed transcript writes leave durable identity unchanged", %{tmp_dir: dir} do
      data = sample_data("failed-transcript")

      assert {:ok, "surviving-token"} =
               SessionStore.establish_remote_token(data.id, "surviving-token", dir)

      transcript_path = Path.join(SessionStore.sessions_dir(dir), "#{data.id}.json")
      File.mkdir_p!(transcript_path)

      assert {:error, _reason} = SessionStore.save(data, dir)

      assert {:ok, "surviving-token"} =
               SessionStore.establish_remote_token(data.id, "replacement-token", dir)
    end
  end

  # ── List ────────────────────────────────────────────────────────────────────

  describe "list/1" do
    test "returns empty list when no sessions exist", %{tmp_dir: dir} do
      # Sessions dir may not exist yet
      sessions = SessionStore.list(dir)
      # Should not crash, returns a list
      assert is_list(sessions)
    end

    test "lists saved sessions with metadata", %{tmp_dir: dir} do
      data1 = sample_data("session-a")
      data2 = sample_data("session-b")
      SessionStore.save(data1, dir)
      SessionStore.save(data2, dir)

      sessions = SessionStore.list(dir)
      ids = Enum.map(sessions, & &1.id)
      assert "session-a" in ids
      assert "session-b" in ids
    end

    test "metadata includes preview from first user message", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      sessions = SessionStore.list(dir)
      session = Enum.find(sessions, &(&1.id == data.id))
      assert session.preview =~ "Hello"
    end

    test "metadata includes model name", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      sessions = SessionStore.list(dir)
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

  describe "retained snapshot durability" do
    test "checkpoint argument captures remain pinned after delivery ends and the store restarts",
         %{tmp_dir: dir} do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      id = "nested-checkpoint-output"
      {:ok, store} = ArtifactStores.ensure_record(id, runtime)

      {output, delivery} =
        store_output(store, "nested", "checkpoint argument bytes", "text/plain")

      {:ok, request, continuation} =
        Continuation.begin_request(Continuation.new(), "nested-request", 1, "inspect")

      assistant = %ReqLLM.Message{
        role: :assistant,
        content: [],
        metadata: %{},
        tool_calls: [ReqLLM.ToolCall.new("nested-call", "inspect", "{}")]
      }

      {:ok, _checkpoint, continuation} =
        Continuation.checkpoint_tool_group(
          continuation,
          request.request_id,
          request.messages ++ [assistant],
          [%{tool_call_id: "nested-call", name: "inspect", arguments: %{"captures" => [output]}}]
        )

      data = %{
        sample_data(id)
        | continuation: continuation,
          messages: [{:user, "inspect"}],
          message_ids: [1],
          pinned_ids: MapSet.new()
      }

      config_dir = Path.join(dir, "config")
      assert :ok = SessionStore.save(data, config_dir, artifact_runtime: runtime)
      assert :ok = ArtifactStore.release(store, delivery)
      assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)
      assert :ok = DynamicSupervisor.terminate_child(runtime.store_supervisor, store)
      assert {:ok, loaded} = SessionStore.load(id, config_dir, artifact_runtime: runtime)
      assert loaded.continuation == continuation
      {:ok, reopened} = ArtifactStores.ensure_record(id, runtime)

      assert {:ok, %{bytes: "checkpoint argument bytes"}} =
               ArtifactStore.fetch(reopened, output.reference, output.selection)

      path = Path.join(SessionStore.sessions_dir(config_dir), "#{id}.json")
      original = File.read!(path)
      current = JSON.decode!(original)
      legacy = current |> Map.put("version", 3) |> Map.delete("artifact_generation")
      File.write!(path, JSON.encode!(legacy))

      assert {:error, :invalid_session_record} =
               SessionStore.load(id, config_dir, artifact_runtime: runtime)

      File.write!(path, original)
    end

    test "version three rejects hybrid model and retained schemas without replacing durable authority",
         %{tmp_dir: dir} do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      id = "hybrid-version-three"
      config_dir = Path.join(dir, "config")

      data = %{
        sample_data(id)
        | messages: [{:user, "hello"}],
          message_ids: [1],
          pinned_ids: MapSet.new()
      }

      assert :ok = SessionStore.save(data, config_dir, artifact_runtime: runtime)
      path = Path.join(SessionStore.sessions_dir(config_dir), "#{id}.json")
      hybrid = File.read!(path) |> JSON.decode!() |> Map.put("version", 3)
      malformed = JSON.encode!(hybrid)
      File.write!(path, malformed)

      assert {:error, :invalid_session_record} =
               SessionStore.load(id, config_dir, artifact_runtime: runtime)

      assert {:error, _reason} = SessionStore.save(data, config_dir, artifact_runtime: runtime)
      assert File.read!(path) == malformed
    end

    test "generationless model snapshots reject output keys in transcripts and branches", %{
      tmp_dir: dir
    } do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      id = "model-output-key"
      config_dir = Path.join(dir, "config")
      {:ok, range} = Range.new(:full, :bytes, 0, 6, 6)
      {:ok, inline} = Output.new("inline", :complete, range)
      data = data_with_output(id, inline, Continuation.new())
      assert :ok = SessionStore.save(data, config_dir, artifact_runtime: runtime)
      path = Path.join(SessionStore.sessions_dir(config_dir), "#{id}.json")
      current = File.read!(path) |> JSON.decode!()
      [call] = current["messages"]

      base =
        current
        |> Map.put("version", 3)
        |> Map.delete("artifact_generation")
        |> Map.put("messages", [Map.delete(call, "output")])

      File.write!(path, JSON.encode!(base))
      assert {:ok, _loaded} = SessionStore.load(id, config_dir, artifact_runtime: runtime)

      for version <- [3, 4],
          output <- [nil, call["output"]],
          location <- [:transcript, :branch] do
        message = Map.put(call, "output", output)

        invalid =
          case location do
            :transcript ->
              Map.put(base, "messages", [message])

            :branch ->
              Map.put(base, "branches", [
                %{"name" => "saved", "created_at" => data.timestamp, "messages" => [message]}
              ])
          end

        malformed = invalid |> Map.put("version", version) |> JSON.encode!()
        File.write!(path, malformed)

        assert {:error, :invalid_session_record} =
                 SessionStore.load(id, config_dir, artifact_runtime: runtime)

        assert {:error, _reason} = SessionStore.save(data, config_dir, artifact_runtime: runtime)
        assert File.read!(path) == malformed
      end
    end

    test "version three retained output preserves original bytes when upgraded to the combined format",
         %{tmp_dir: dir} do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      id = "retained-version-three"
      {:ok, store} = ArtifactStores.ensure_record(id, runtime)

      {output, delivery} =
        store_output(store, "legacy-retained", "original version-three bytes", "text/plain")

      data = data_with_output(id, output, Continuation.new())
      config_dir = Path.join(dir, "config")
      assert :ok = SessionStore.save(data, config_dir, artifact_runtime: runtime)
      assert :ok = ArtifactStore.release(store, delivery)
      path = Path.join(SessionStore.sessions_dir(config_dir), "#{id}.json")

      legacy =
        path
        |> File.read!()
        |> JSON.decode!()
        |> Map.put("version", 3)
        |> Map.delete("model_selection")
        |> Map.delete("selection_intent")

      File.write!(path, JSON.encode!(legacy))
      assert :ok = DynamicSupervisor.terminate_child(runtime.store_supervisor, store)

      assert {:ok, loaded} = SessionStore.load(id, config_dir, artifact_runtime: runtime)
      assert loaded.model_selection == nil

      assert loaded.selection_intent == %{
               "model" => data.model_name,
               "provider" => data.provider_name
             }

      assert :ok = SessionStore.save(loaded, config_dir, artifact_runtime: runtime)
      {:ok, reopened} = ArtifactStores.ensure_record(id, runtime)
      [{:tool_call, call}] = loaded.messages

      assert {:ok, %{bytes: "original version-three bytes"}} =
               ArtifactStore.fetch(reopened, call.output.reference, call.output.selection)
    end

    test "pins transcript, inactive branch, and checkpoint refs across store restart", %{
      tmp_dir: dir
    } do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      session_id = "retained-restart"
      {:ok, store} = ArtifactStores.ensure_record(session_id, runtime)

      {transcript_output, transcript_delivery} =
        store_output(store, "transcript", "transcript exact bytes", "text/plain")

      {branch_output, branch_delivery} =
        store_output(store, "branch", "image exact bytes", "image/png")

      {checkpoint_output, checkpoint_delivery} =
        store_output(store, "checkpoint", "checkpoint exact bytes", "text/plain")

      continuation = continuation_with_outputs(branch_output, checkpoint_output)
      data = data_with_output(session_id, transcript_output, continuation)
      config_dir = Path.join(dir, "config")

      assert :ok = SessionStore.save(data, config_dir, artifact_runtime: runtime)

      for delivery <- [transcript_delivery, branch_delivery, checkpoint_delivery] do
        assert :ok = ArtifactStore.release(store, delivery)
      end

      assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)

      path = Path.join(SessionStore.sessions_dir(config_dir), "#{session_id}.json")
      snapshot = File.read!(path)
      refute snapshot =~ "transcript exact bytes"
      refute snapshot =~ "image exact bytes"
      refute snapshot =~ "checkpoint exact bytes"

      assert :ok = DynamicSupervisor.terminate_child(runtime.store_supervisor, store)
      assert {:ok, reopened} = ArtifactStores.ensure_record(session_id, runtime)

      assert {:ok, loaded} =
               SessionStore.load(session_id, config_dir, artifact_runtime: runtime)

      [{:tool_call, transcript_call}] = loaded.messages
      assert transcript_call.output == transcript_output
      assert loaded.continuation == continuation

      for {output, bytes} <- [
            {transcript_output, "transcript exact bytes"},
            {branch_output, "image exact bytes"},
            {checkpoint_output, "checkpoint exact bytes"}
          ] do
        assert {:ok, %{bytes: ^bytes}} =
                 ArtifactStore.fetch(reopened, output.reference, output.selection)
      end
    end

    test "a definite pre-rename failure releases the candidate pin and preserves old JSON", %{
      tmp_dir: dir
    } do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      session_id = "pin-before-write"
      {:ok, store} = ArtifactStores.ensure_record(session_id, runtime)
      {old_output, old_delivery} = store_output(store, "old", "old bytes", "text/plain")
      config_dir = Path.join(dir, "config")
      old_data = data_with_output(session_id, old_output, Continuation.new())

      assert :ok = SessionStore.save(old_data, config_dir, artifact_runtime: runtime)
      assert :ok = ArtifactStore.release(store, old_delivery)

      path = Path.join(SessionStore.sessions_dir(config_dir), "#{session_id}.json")
      old_json = File.read!(path)
      {new_output, new_delivery} = store_output(store, "new", "new bytes", "text/plain")
      candidate = data_with_output(session_id, new_output, Continuation.new())

      assert {:error, :injected_pre_rename_failure} =
               SessionStore.save(candidate, config_dir,
                 artifact_runtime: runtime,
                 fault_injector: %{
                   before_session_snapshot_rename: {:error, :injected_pre_rename_failure}
                 }
               )

      assert File.read!(path) == old_json

      assert {:ok, loaded} =
               SessionStore.load(session_id, config_dir, artifact_runtime: runtime)

      assert [{:tool_call, %ToolCall{output: ^old_output}}] = loaded.messages
      assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)

      assert {:ok, %{bytes: "old bytes"}} =
               ArtifactStore.fetch(store, old_output.reference, old_output.selection)

      assert {:ok, %{bytes: "new bytes"}} =
               ArtifactStore.fetch(store, new_output.reference, new_output.selection)

      assert :ok = SessionStore.save(candidate, config_dir, artifact_runtime: runtime)
      assert :ok = ArtifactStore.release(store, new_delivery)
      assert {:ok, 1} = ArtifactStore.cleanup_unreferenced(store)

      assert {:error, :expired} =
               ArtifactStore.fetch(store, old_output.reference, old_output.selection)

      assert {:ok, %{bytes: "new bytes"}} =
               ArtifactStore.fetch(store, new_output.reference, new_output.selection)
    end

    test "a post-rename failure retains the ambiguous candidate until load reconciles JSON", %{
      tmp_dir: dir
    } do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      session_id = "pin-after-rename"
      {:ok, store} = ArtifactStores.ensure_record(session_id, runtime)
      {old_output, old_delivery} = store_output(store, "old", "old bytes", "text/plain")
      config_dir = Path.join(dir, "config")

      assert :ok =
               SessionStore.save(
                 data_with_output(session_id, old_output, Continuation.new()),
                 config_dir,
                 artifact_runtime: runtime
               )

      assert :ok = ArtifactStore.release(store, old_delivery)
      {new_output, _new_delivery} = store_output(store, "new", "new bytes", "text/plain")

      assert {:error, :injected_post_rename_failure} =
               SessionStore.save(
                 data_with_output(session_id, new_output, Continuation.new()),
                 config_dir,
                 artifact_runtime: runtime,
                 fault_injector: %{
                   after_session_snapshot_rename: {:error, :injected_post_rename_failure}
                 }
               )

      assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)

      recovery_fault = %{before_session_snapshot_recovery_sync: {:error, :recovery_sync_failed}}

      assert {:error, :recovery_sync_failed} =
               SessionStore.load(session_id, config_dir,
                 artifact_runtime: runtime,
                 fault_injector: recovery_fault
               )

      assert {:error, :recovery_sync_failed} =
               SessionStore.save(
                 data_with_output(session_id, new_output, Continuation.new()),
                 config_dir,
                 artifact_runtime: runtime,
                 fault_injector: recovery_fault
               )

      assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)

      assert {:ok, %{bytes: "old bytes"}} =
               ArtifactStore.fetch(store, old_output.reference, old_output.selection)

      assert {:ok, %{bytes: "new bytes"}} =
               ArtifactStore.fetch(store, new_output.reference, new_output.selection)

      assert {:ok, loaded} =
               SessionStore.load(session_id, config_dir, artifact_runtime: runtime)

      assert [{:tool_call, %ToolCall{output: ^new_output}}] = loaded.messages
      assert {:ok, 1} = ArtifactStore.cleanup_unreferenced(store)

      assert {:error, :expired} =
               ArtifactStore.fetch(store, old_output.reference, old_output.selection)

      assert {:ok, %{bytes: "new bytes"}} =
               ArtifactStore.fetch(store, new_output.reference, new_output.selection)
    end

    test "serializable invalid candidates cannot replace a resumable snapshot or release its output",
         %{tmp_dir: dir} do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      id = "candidate-schema"
      {:ok, store} = ArtifactStores.ensure_record(id, runtime)
      {output, delivery} = store_output(store, "protected", "resumable bytes", "text/plain")
      config_dir = Path.join(dir, "config")

      assert :ok =
               SessionStore.save(data_with_output(id, output, Continuation.new()), config_dir,
                 artifact_runtime: runtime
               )

      assert :ok = ArtifactStore.release(store, delivery)
      path = Path.join(SessionStore.sessions_dir(config_dir), "#{id}.json")
      original = File.read!(path)
      base = sample_data(id)

      candidates = [
        %{base | title: ""},
        %{base | timestamp: "invalid-time"},
        %{base | message_ids: [10, 10, 30, 40, 50, 60]}
      ]

      for candidate <- candidates do
        assert {:error, :invalid_session_record} =
                 SessionStore.save(candidate, config_dir, artifact_runtime: runtime)

        assert File.read!(path) == original
        assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)

        assert {:ok, %{bytes: "resumable bytes"}} =
                 ArtifactStore.fetch(store, output.reference, output.selection)
      end
    end

    test "malformed legacy message content is not authoritative absence", %{tmp_dir: dir} do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      id = "legacy-schema"
      {:ok, store} = ArtifactStores.ensure_record(id, runtime)

      {output, delivery} =
        store_output(store, "protected", "legacy ambiguity bytes", "text/plain")

      config_dir = Path.join(dir, "config")

      assert :ok =
               SessionStore.save(data_with_output(id, output, Continuation.new()), config_dir,
                 artifact_runtime: runtime
               )

      assert :ok = ArtifactStore.release(store, delivery)
      path = Path.join(SessionStore.sessions_dir(config_dir), "#{id}.json")

      legacy = %{
        "version" => 1,
        "id" => id,
        "timestamp" => "2026-01-01T00:00:00Z",
        "model_name" => "test-model",
        "messages" => [%{"type" => "user", "text" => "valid prompt"}]
      }

      invalid = [
        Map.put(legacy, "messages", [%{"type" => "user", "text" => 42}]),
        Map.put(legacy, "branches", [
          %{
            "name" => "branch",
            "created_at" => "2026-01-01T00:00:00Z",
            "messages" => [%{"type" => "assistant", "text" => 42}]
          }
        ])
      ]

      for record <- invalid do
        json = JSON.encode!(record)
        File.write!(path, json)

        assert {:error, :invalid_session_record} =
                 SessionStore.save(sample_data(id), config_dir, artifact_runtime: runtime)

        assert File.read!(path) == json
        assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)

        assert {:ok, %{bytes: "legacy ambiguity bytes"}} =
                 ArtifactStore.fetch(store, output.reference, output.selection)
      end
    end

    test "artifact actor exit after candidate pinning does not report a durable commit as failure",
         %{tmp_dir: dir} do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      id = "actor-exit-after-pin"
      {:ok, store} = ArtifactStores.ensure_record(id, runtime)

      {output, _delivery} =
        store_output(store, "candidate", "committed despite actor exit", "text/plain")

      config_dir = Path.join(dir, "config")
      parent = self()

      fault = fn
        :before_session_snapshot_rename ->
          send(parent, {:candidate_pinned, self()})

          receive do
            :resume_snapshot -> :ok
          end

        _point ->
          :ok
      end

      writer =
        Task.async(fn ->
          SessionStore.save(data_with_output(id, output, Continuation.new()), config_dir,
            artifact_runtime: runtime,
            fault_injector: fault
          )
        end)

      # The test timeout bounds this handshake; pinning has no one-second latency contract.
      writer_pid =
        receive do
          {:candidate_pinned, writer_pid} ->
            writer_pid

          {ref, result} when ref == writer.ref ->
            flunk("snapshot writer returned before candidate pinning: #{inspect(result)}")
        end

      assert :ok = DynamicSupervisor.terminate_child(runtime.store_supervisor, store)
      send(writer_pid, :resume_snapshot)
      assert :ok = Task.await(writer)
      assert {:ok, loaded} = SessionStore.load(id, config_dir, artifact_runtime: runtime)
      assert [{:tool_call, %ToolCall{output: ^output}}] = loaded.messages
      {:ok, reopened} = ArtifactStores.ensure_record(id, runtime)

      assert {:ok, %{bytes: "committed despite actor exit"}} =
               ArtifactStore.fetch(reopened, output.reference, output.selection)
    end

    test "zero-reference records report configured runtime failures without replacing JSON", %{
      tmp_dir: dir
    } do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      config_dir = Path.join(dir, "config")
      id = "empty-output-authority"
      data = sample_data(id)
      assert :ok = SessionStore.save(data, config_dir, artifact_runtime: runtime)
      path = Path.join(SessionStore.sessions_dir(config_dir), "#{id}.json")
      original = File.read!(path)

      options = [
        root: runtime.root,
        quota: runtime.quota,
        registry: runtime.registry,
        store_supervisor: runtime.store_supervisor,
        limits: runtime.limits
      ]

      missing = Module.concat(__MODULE__, "MissingRuntime#{System.unique_integer([:positive])}")

      for key <- [:quota, :registry] do
        {:ok, unavailable} =
          MingaAgent.ArtifactStores.Runtime.new(Keyword.put(options, key, missing))

        assert {:error, _reason} =
                 SessionStore.load(id, config_dir, artifact_runtime: unavailable)

        assert {:error, _reason} =
                 SessionStore.save(data, config_dir, artifact_runtime: unavailable)

        assert File.read!(path) == original
      end
    end

    test "invalid JSON authority never reconciles snapshot pins", %{tmp_dir: dir} do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      id = "invalid-authority"
      {:ok, store} = ArtifactStores.ensure_record(id, runtime)
      {output, delivery} = store_output(store, "authority", "protected authority", "text/plain")

      {orphan, orphan_delivery} =
        store_output(store, "ambiguous", "protected candidate", "text/plain")

      config_dir = Path.join(dir, "config")

      assert :ok =
               SessionStore.save(data_with_output(id, output, Continuation.new()), config_dir,
                 artifact_runtime: runtime
               )

      assert :ok = ArtifactStore.release(store, delivery)
      foreign = String.duplicate("0", 64)
      assert :ok = ArtifactStore.pin(store, {:snapshot, foreign}, Output.references(orphan))
      assert :ok = ArtifactStore.release(store, orphan_delivery)
      path = Path.join(SessionStore.sessions_dir(config_dir), "#{id}.json")
      valid = path |> File.read!() |> JSON.decode!()

      for invalid <- [Map.put(valid, "artifact_generation", foreign), Map.put(valid, "title", 42)] do
        File.write!(path, JSON.encode!(invalid))

        assert {:error, :invalid_session_record} =
                 SessionStore.load(id, config_dir, artifact_runtime: runtime)

        assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)

        assert {:ok, %{bytes: "protected authority"}} =
                 ArtifactStore.fetch(store, output.reference, output.selection)

        assert {:ok, %{bytes: "protected candidate"}} =
                 ArtifactStore.fetch(store, orphan.reference, orphan.selection)
      end
    end

    test "corrupt and unreadable prior records stop save before pin mutation", %{tmp_dir: dir} do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      config_dir = Path.join(dir, "config")

      for kind <- [:corrupt, :directory] do
        id = "invalid-prior-#{kind}"
        {:ok, store} = ArtifactStores.ensure_record(id, runtime)
        {old, delivery} = store_output(store, "old", "prior bytes", "text/plain")
        {new, _delivery} = store_output(store, "new", "retry bytes", "text/plain")

        assert :ok =
                 SessionStore.save(data_with_output(id, old, Continuation.new()), config_dir,
                   artifact_runtime: runtime
                 )

        assert :ok = ArtifactStore.release(store, delivery)
        path = Path.join(SessionStore.sessions_dir(config_dir), "#{id}.json")

        case kind do
          :corrupt ->
            File.write!(path, "{not JSON")

          :directory ->
            File.rm!(path)
            File.mkdir!(path)
        end

        assert {:error, _reason} =
                 SessionStore.save(data_with_output(id, new, Continuation.new()), config_dir,
                   artifact_runtime: runtime
                 )

        assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)

        assert {:ok, %{bytes: "prior bytes"}} =
                 ArtifactStore.fetch(store, old.reference, old.selection)

        assert {:ok, %{bytes: "retry bytes"}} =
                 ArtifactStore.fetch(store, new.reference, new.selection)
      end
    end

    test "a load waits for the same JSON authority while another root remains independent", %{
      tmp_dir: dir
    } do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      independent_runtime = start_artifact_runtime(Path.join(dir, "independent-artifacts"))
      id = "serialized-authority"
      {:ok, store} = ArtifactStores.ensure_record(id, runtime)
      {old, old_delivery} = store_output(store, "old", "old authority", "text/plain")
      {new, _delivery} = store_output(store, "new", "new authority", "text/plain")
      config_dir = Path.join(dir, "config")

      assert :ok =
               SessionStore.save(data_with_output(id, old, Continuation.new()), config_dir,
                 artifact_runtime: runtime
               )

      assert :ok = ArtifactStore.release(store, old_delivery)
      owner = self()

      fault = fn
        :before_session_snapshot_rename ->
          send(owner, {:candidate_pinned, self()})

          receive do
            :resume_snapshot -> :ok
          end

        _point ->
          :ok
      end

      writer =
        Task.async(fn ->
          SessionStore.save(data_with_output(id, new, Continuation.new()), config_dir,
            artifact_runtime: runtime,
            fault_injector: fault
          )
        end)

      assert_receive {:candidate_pinned, writer_pid}

      reader =
        Task.async(fn ->
          send(owner, :reader_started)
          SessionStore.load(id, Path.join(config_dir, "."), artifact_runtime: runtime)
        end)

      assert_receive :reader_started

      assert :ok =
               SessionStore.save(sample_data(id), Path.join(dir, "independent-config"),
                 artifact_runtime: independent_runtime
               )

      assert Task.yield(reader, 0) == nil
      assert {:ok, 0} = ArtifactStore.cleanup_unreferenced(store)
      send(writer_pid, :resume_snapshot)
      assert :ok = Task.await(writer)
      assert {:ok, loaded} = Task.await(reader)
      assert [{:tool_call, %ToolCall{output: ^new}}] = loaded.messages
      assert {:ok, 1} = ArtifactStore.cleanup_unreferenced(store)

      assert {:ok, %{bytes: "new authority"}} =
               ArtifactStore.fetch(store, new.reference, new.selection)
    end

    test "a failed old-pin release after commit does not turn a durable save into failure", %{
      tmp_dir: dir
    } do
      root = Path.join(dir, "artifacts")
      runtime = start_artifact_runtime(root)
      faults = :atomics.new(2, signed: false)
      session_id = "release-leak"
      store = start_faulted_store(runtime, session_id, release_fault(faults))
      {old_output, old_delivery} = store_output(store, "old", "old pinned", "text/plain")
      config_dir = Path.join(dir, "config")

      assert :ok =
               SessionStore.save(
                 data_with_output(session_id, old_output, Continuation.new()),
                 config_dir,
                 artifact_runtime: runtime
               )

      assert :ok = ArtifactStore.release(store, old_delivery)
      {new_output, _new_delivery} = store_output(store, "new", "new pinned", "text/plain")
      :atomics.put(faults, 1, 1)
      :atomics.put(faults, 2, 0)

      assert :ok =
               SessionStore.save(
                 data_with_output(session_id, new_output, Continuation.new()),
                 config_dir,
                 artifact_runtime: runtime
               )

      assert :ok = DynamicSupervisor.terminate_child(runtime.store_supervisor, store)
      assert {:ok, reopened} = ArtifactStores.ensure_record(session_id, runtime)

      assert {:ok, loaded} =
               SessionStore.load(session_id, config_dir, artifact_runtime: runtime)

      assert [{:tool_call, %ToolCall{output: ^new_output}}] = loaded.messages

      assert {:ok, %{bytes: "new pinned"}} =
               ArtifactStore.fetch(reopened, new_output.reference, new_output.selection)
    end

    test "deletes JSON durably before artifact drop and leaves failed drops charged", %{
      tmp_dir: dir
    } do
      runtime = start_artifact_runtime(Path.join(dir, "artifacts"))
      session_id = "ordered-delete"
      {:ok, store} = ArtifactStores.ensure_record(session_id, runtime)
      {output, delivery} = store_output(store, "retained", "retained bytes", "text/plain")
      config_dir = Path.join(dir, "config")

      assert :ok =
               SessionStore.save(
                 data_with_output(session_id, output, Continuation.new()),
                 config_dir,
                 artifact_runtime: runtime
               )

      assert :ok = ArtifactStore.release(store, delivery)
      active = begin_output_capture(store, "still-active", "text/plain")

      assert {:error, :record_in_use} =
               SessionStore.delete(session_id, config_dir, artifact_runtime: runtime)

      path = Path.join(SessionStore.sessions_dir(config_dir), "#{session_id}.json")
      refute File.exists?(path)
      assert %{namespaces: 1, artifacts: 2} = ArtifactQuota.usage(runtime.quota)

      assert {:ok, %{bytes: "retained bytes"}} =
               ArtifactStore.fetch(store, output.reference, output.selection)

      assert {:ok, _stored} = ArtifactStore.finish(store, active, :complete)
      assert :ok = SessionStore.delete(session_id, config_dir, artifact_runtime: runtime)
      assert %{namespaces: 0, artifacts: 0} = ArtifactQuota.usage(runtime.quota)
    end
  end

  # ── Delete ──────────────────────────────────────────────────────────────────

  describe "delete/2" do
    test "deletes a saved session", %{tmp_dir: dir} do
      data = sample_data()
      SessionStore.save(data, dir)

      assert :ok = SessionStore.delete(data.id, dir)
      assert {:error, _} = SessionStore.load(data.id, dir)
    end
  end

  # ── Clear all ───────────────────────────────────────────────────────────────

  describe "clear_all/1" do
    test "removes all sessions", %{tmp_dir: dir} do
      SessionStore.save(sample_data("s1"), dir)
      SessionStore.save(sample_data("s2"), dir)

      SessionStore.clear_all(dir)

      assert {:error, _} = SessionStore.load("s1", dir)
      assert {:error, _} = SessionStore.load("s2", dir)
    end
  end

  # ── Atomic writes ──────────────────────────────────────────────────────────

  describe "atomic writes" do
    test "overwrites an existing session", %{tmp_dir: dir} do
      data1 = %{
        sample_data()
        | messages: [{:user, "first"}],
          message_ids: [1],
          pinned_ids: MapSet.new()
      }

      data2 = %{data1 | messages: [{:user, "second"}]}

      SessionStore.save(data1, dir)
      SessionStore.save(data2, dir)

      {:ok, loaded} = SessionStore.load(data1.id, dir)
      assert [{:user, "second"}] = loaded.messages
    end

    test "a non-serializable pid leaves the prior durable snapshot unchanged", %{tmp_dir: dir} do
      data = %{
        sample_data("pid-rejected")
        | messages: [{:user, "durable"}],
          message_ids: [1],
          pinned_ids: MapSet.new()
      }

      assert :ok = SessionStore.save(data, dir)
      path = Path.join(SessionStore.sessions_dir(dir), "#{data.id}.json")
      durable_json = File.read!(path)

      invalid_call = ToolCall.new("pid-call", "test", %{"owner" => self()})

      invalid = %{
        data
        | messages: [{:tool_call, invalid_call}],
          message_ids: [2]
      }

      assert {:error, {:snapshot_encode_failed, _reason}} = SessionStore.save(invalid, dir)
      assert File.read!(path) == durable_json
      refute durable_json =~ "#PID"
      assert {:ok, %{messages: [{:user, "durable"}]}} = SessionStore.load(data.id, dir)
    end

    test "imports version two text without inventing complete output facts", %{tmp_dir: dir} do
      tool_call =
        ToolCall.new("legacy-truncated", "read_file")
        |> ToolCall.complete("prefix [truncated]")

      data = %{
        sample_data("version-two-output")
        | messages: [{:tool_call, tool_call}],
          message_ids: [1],
          pinned_ids: MapSet.new()
      }

      assert :ok = SessionStore.save(data, dir)
      path = Path.join(SessionStore.sessions_dir(dir), "#{data.id}.json")
      current = path |> File.read!() |> JSON.decode!()

      legacy_messages =
        Enum.map(current["messages"], fn message -> Map.delete(message, "output") end)

      legacy =
        current
        |> Map.put("version", 2)
        |> Map.delete("artifact_generation")
        |> Map.put("messages", legacy_messages)
        |> put_in(["continuation", "version"], 2)

      File.write!(path, JSON.encode!(legacy))

      assert {:ok, %{messages: [{:tool_call, loaded}]}} =
               SessionStore.load(data.id, dir)

      assert loaded.result == "prefix [truncated]"
      assert loaded.output == nil
    end
  end

  # ── Prune ───────────────────────────────────────────────────────────────────

  describe "prune/2" do
    test "removes sessions older than N days", %{tmp_dir: dir} do
      old_ts = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60 * 86_400, :second))
      new_ts = DateTime.to_iso8601(DateTime.utc_now())

      old_data = %{sample_data("old-session") | timestamp: old_ts}
      new_data = %{sample_data("new-session") | timestamp: new_ts}

      SessionStore.save(old_data, dir)
      SessionStore.save(new_data, dir)

      pruned = SessionStore.prune(30, dir)
      assert pruned >= 1

      assert {:error, _} = SessionStore.load("old-session", dir)
      assert {:ok, _} = SessionStore.load("new-session", dir)
    end

    test "does not remove sessions within retention period", %{tmp_dir: dir} do
      data = sample_data("recent-session")
      SessionStore.save(data, dir)

      pruned = SessionStore.prune(30, dir)
      assert pruned == 0
      assert {:ok, _} = SessionStore.load("recent-session", dir)
    end

    test "pruning a transcript does not revoke its durable identity", %{tmp_dir: dir} do
      session_id = "old-transcript-stable-token"
      old_timestamp = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -40, :day))
      data = %{sample_data(session_id) | timestamp: old_timestamp}

      assert :ok = SessionStore.save(data, dir)

      assert {:ok, "stable-token"} =
               SessionStore.establish_remote_token(session_id, "stable-token", dir)

      assert SessionStore.prune(30, dir) == 1
      assert {:error, _reason} = SessionStore.load(session_id, dir)

      assert {:ok, "stable-token"} =
               SessionStore.establish_remote_token(session_id, "replacement-token", dir)
    end
  end

  @spec start_artifact_runtime(String.t()) :: MingaAgent.ArtifactStores.Runtime.t()
  defp start_artifact_runtime(root) do
    suffix = System.unique_integer([:positive])

    opts = [
      name: Module.concat(__MODULE__, "ArtifactSupervisor#{suffix}"),
      root: root,
      quota: Module.concat(__MODULE__, "ArtifactQuota#{suffix}"),
      registry: Module.concat(__MODULE__, "ArtifactRegistry#{suffix}"),
      store_supervisor: Module.concat(__MODULE__, "ArtifactStores#{suffix}")
    ]

    child =
      Supervisor.child_spec({ArtifactSupervisor, opts},
        id: {:session_store_artifacts, suffix},
        restart: :temporary
      )

    _supervisor = start_supervised!(child)
    {:ok, runtime} = ArtifactSupervisor.runtime(opts)
    runtime
  end

  @spec start_faulted_store(
          MingaAgent.ArtifactStores.Runtime.t(),
          String.t(),
          MingaAgent.ArtifactStorage.FaultInjector.t()
        ) :: GenServer.server()
  defp start_faulted_store(runtime, session_id, fault_injector) do
    name = {:via, Registry, {runtime.registry, session_id}}

    child =
      Supervisor.child_spec(
        {ArtifactStore,
         root: runtime.root,
         quota: runtime.quota,
         session_id: session_id,
         limits: runtime.limits,
         name: name,
         fault_injector: fault_injector},
        restart: :transient
      )

    {:ok, store} = DynamicSupervisor.start_child(runtime.store_supervisor, child)
    store
  end

  @spec release_fault(:atomics.atomics_ref()) :: MingaAgent.ArtifactStorage.FaultInjector.t()
  defp release_fault(faults) do
    fn
      :before_metadata_checkpoint ->
        release_fault_checkpoint(faults, :atomics.get(faults, 1))

      _point ->
        :ok
    end
  end

  @spec release_fault_checkpoint(:atomics.atomics_ref(), 0 | 1) ::
          :ok | {:error, :injected_old_pin_release_failure}
  defp release_fault_checkpoint(_faults, 0), do: :ok

  defp release_fault_checkpoint(faults, 1) do
    case :atomics.add_get(faults, 2, 1) do
      3 -> {:error, :injected_old_pin_release_failure}
      _other -> :ok
    end
  end

  @spec data_with_output(String.t(), Output.t(), Continuation.t()) ::
          SessionStore.session_data()
  defp data_with_output(session_id, output, continuation) do
    tool_call =
      ToolCall.new("display-call", "read_file") |> ToolCall.complete(output.view, output)

    %{
      sample_data(session_id)
      | messages: [{:tool_call, tool_call}],
        message_ids: [1],
        pinned_ids: MapSet.new(),
        continuation: continuation
    }
  end

  @spec store_output(GenServer.server(), String.t(), binary(), String.t()) ::
          {Output.t(), tuple()}
  defp store_output(store, call_id, payload, media_type) do
    capture = begin_output_capture(store, call_id, media_type)
    assert {:ok, _progress} = ArtifactStore.append(store, capture, payload)
    assert {:ok, stored} = ArtifactStore.finish(store, capture, :complete)
    {:ok, range} = Range.new(:full, :bytes, 0, byte_size(payload), byte_size(payload))

    attachments =
      case media_type do
        "image/png" ->
          {:ok, attachment} = Attachment.image(stored.reference, "#{call_id}.png")
          [attachment]

        _text ->
          []
      end

    {:ok, output} =
      Output.new("#{call_id} output", stored.capture, range,
        reference: stored.reference,
        attachments: attachments
      )

    {output, {:delivery, "snapshot-test", call_id}}
  end

  @spec begin_output_capture(GenServer.server(), String.t(), String.t()) :: term()
  defp begin_output_capture(store, call_id, media_type) do
    {:ok, spec} =
      CaptureSpec.new(
        media_type: media_type,
        mode: :bytes,
        owner_pid: self(),
        delivery_key: {:delivery, "snapshot-test", call_id}
      )

    {:ok, capture} = ArtifactStore.begin(store, spec)
    capture
  end

  @spec continuation_with_outputs(Output.t(), Output.t()) :: Continuation.t()
  defp continuation_with_outputs(branch_output, checkpoint_output) do
    frozen_result =
      Context.tool_result_message("read_file", "frozen-call", branch_output.view, %{
        output: branch_output
      })

    {:ok, continuation} =
      Continuation.restore(
        [],
        0,
        0,
        [],
        %{"inactive" => %{messages: [frozen_result], boundaries: []}},
        :lossless
      )

    {:ok, request, continuation} =
      Continuation.begin_request(continuation, "snapshot-request", 1, "inspect")

    assistant = %ReqLLM.Message{
      role: :assistant,
      content: [],
      metadata: %{},
      tool_calls: [ReqLLM.ToolCall.new("current-call", "read_file", ~s({"path":"a"}))]
    }

    {:ok, checkpoint_id, continuation} =
      Continuation.checkpoint_tool_group(
        continuation,
        request.request_id,
        request.messages ++ [assistant],
        [
          %{
            tool_call_id: "current-call",
            name: "read_file",
            arguments: %{"path" => "a"}
          }
        ]
      )

    {:ok, continuation} =
      Continuation.admit_tool_effect(
        continuation,
        request.request_id,
        checkpoint_id,
        "current-call",
        "read_file",
        %{"path" => "a"}
      )

    result =
      Context.tool_result_message("read_file", "current-call", checkpoint_output.view, %{
        output: checkpoint_output
      })

    {:ok, continuation} =
      Continuation.complete_tool_effect(
        continuation,
        request.request_id,
        checkpoint_id,
        "current-call",
        result
      )

    continuation
  end

  @spec retained_text_output(String.t(), binary()) :: Output.t()
  defp retained_text_output(id, payload) do
    reference = retained_reference(id, "text/plain", payload)
    {:ok, range} = Range.new(:full, :bytes, 0, byte_size(payload), byte_size(payload))

    {:ok, revision} =
      Revision.new(
        source_kind: :disk,
        source_id: "fixture.txt",
        scope: range,
        generation: 7,
        sha256: Reference.digest(payload)
      )

    {:ok, output} =
      Output.new("full retained", :complete, range,
        presentation: {:truncated, 5},
        reference: reference,
        revision: revision
      )

    output
  end

  @spec retained_image_output(String.t(), binary()) :: Output.t()
  defp retained_image_output(id, payload) do
    reference = retained_reference(id, "image/png", payload)
    {:ok, attachment} = Attachment.image(reference, "fixture.png")
    {:ok, range} = Range.new(:full, :bytes, 0, byte_size(payload), byte_size(payload))

    {:ok, output} =
      Output.new("[image: fixture.png]", :complete, range,
        reference: reference,
        attachments: [attachment]
      )

    output
  end

  @spec retained_reference(String.t(), String.t(), binary()) :: Reference.t()
  defp retained_reference(id, media_type, payload) do
    artifact_id = String.pad_trailing(id, 32, "x")
    {:ok, token} = Reference.token("codec-session", artifact_id)

    {:ok, reference} =
      Reference.new(
        token: token,
        media_type: media_type,
        bytes: byte_size(payload),
        sha256: Reference.digest(payload)
      )

    reference
  end

  @spec private_mode?(non_neg_integer(), non_neg_integer()) :: boolean()
  defp private_mode?(mode, mask) do
    Bitwise.band(mode, mask) == 0
  end

  defp model_selection,
    do: MingaAgent.Test.ModelSelectionFixture.selection(model_provider: "test")
end
