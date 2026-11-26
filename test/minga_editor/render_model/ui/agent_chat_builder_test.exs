defmodule MingaEditor.RenderModel.UI.AgentChatBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.PromptBuffer
  alias Minga.Test.TranscriptFixture
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.StartRequest
  alias MingaEditor.Agent.UIState
  alias MingaAgent.Session.{ConnectionSnapshot, ConnectionTarget}
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.Session.Transcript, as: SourceTranscript
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.{Range, Reference}
  alias MingaAgent.ToolApproval
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Public, as: PublicApproval
  alias MingaAgent.ToolApproval.Target, as: ApprovalTarget
  alias MingaAgent.ToolCall
  alias Minga.Config.Options
  alias Minga.Editing.Scroll
  alias Minga.Frontend.Adapter.GUI.AgentChatMessageCodec
  alias Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder
  alias Minga.Frontend.Adapter.GUI.Caches
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.TranscriptUpdate
  alias MingaEditor.RenderPipeline.TestHelpers
  alias Minga.RenderModel.UI.AgentChat.ApprovalView
  alias Minga.RenderModel.UI.AgentChat.MarkdownBlock
  alias Minga.RenderModel.UI.AgentChat.StartRemedy
  alias Minga.RenderModel.UI.AgentChat.ToolCallView
  alias MingaEditor.UI.Theme
  alias MingaEditor.RenderModel.UI.AgentChatBuilder
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Appearance
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Window

  @retry_remedy %StartRemedy{kind: :retry, label: "Retry", key_hint: "r"}

  test "visible pending discovery does not claim a missing model" do
    session = fake_session_pid()
    panel = synced_panel([]) |> Panel.set_model_name("unknown")

    for readiness <- [:checking, :configured] do
      model =
        context(session, Panel.set_credential_readiness(panel, readiness))
        |> AgentChatBuilder.build()

      assert model.visible?
      assert model.model_name == "Resolving model…"
    end
  end

  describe "model identity" do
    test "a contributed route selection names the route's display name as its provider" do
      selection =
        ModelSelectionFixture.selection(
          request_provider: :contributed,
          origin: {:contributed, "claude_bridge", "haiku"},
          model_provider: "claude_bridge",
          model_id: "haiku",
          route_id: "claude_bridge/haiku",
          display_name: "Claude Haiku",
          provider_label: "Claude (subscription)"
        )

      assert built_model_name(selection) == "Claude (subscription):Claude Haiku"
    end

    test "a built-in selection names its catalog provider" do
      selection =
        ModelSelectionFixture.selection(
          request_provider: :anthropic,
          model_id: "claude-sonnet-4-5",
          display_name: "Claude Sonnet 4.5",
          provider_label: "Anthropic"
        )

      assert built_model_name(selection) == "Anthropic:Claude Sonnet 4.5"
    end

    test "a route display name containing the frontend separator is not split" do
      selection =
        ModelSelectionFixture.selection(
          request_provider: :contributed,
          origin: {:contributed, "bridge", "haiku"},
          model_provider: "bridge",
          model_id: "haiku",
          route_id: "bridge/haiku",
          display_name: "Claude Haiku",
          provider_label: "Bridge: Claude"
        )

      assert built_model_name(selection) == "Claude Haiku"
    end
  end

  defp built_model_name(selection) do
    session = fake_session_pid()

    connection = %ConnectionSnapshot{
      target: ConnectionTarget.new(session, "model-identity", nil, make_ref()),
      credential_readiness: :configured,
      model_selection: selection,
      provider_phase: :running,
      operation: :idle,
      problem: nil
    }

    context(session, synced_panel([]), connection: connection)
    |> AgentChatBuilder.build()
    |> Map.fetch!(:model_name)
  end

  describe "a failed start" do
    test "presents its cause and the one remedy with the key the Agent scope binds" do
      session = fake_session_pid()
      request = StartRequest.default()

      for {failure, remedy} <- [
            {StartFailure.catalog_unavailable(request), @retry_remedy},
            {StartFailure.timed_out(request), @retry_remedy},
            {StartFailure.session_error(:boom, request), @retry_remedy},
            {StartFailure.session_crashed(self()), @retry_remedy},
            {StartFailure.session_crashed(remote_pid()), nil},
            {StartFailure.missing_credentials(),
             %StartRemedy{kind: :set_up_provider, label: "Set up provider", key_hint: "r"}}
          ] do
        model =
          context(session, synced_panel([]), lifecycle: {:failed, failure})
          |> AgentChatBuilder.build()

        assert model.lifecycle == {:failed, failure.message, remedy}
      end
    end

    test "the key hint names the key that works where focus is" do
      session = fake_session_pid()
      failure = StartFailure.timed_out(StartRequest.default())

      for {model, focused?, hint} <- [
            {:vim, false, "r"},
            {:vim, true, "Enter"},
            {:cua, false, "Enter"},
            {:cua, true, "Enter"}
          ] do
        panel = %{synced_panel([]) | input_focused: focused?}
        ctx = context(session, panel, lifecycle: {:failed, failure})
        ctx = put_in(ctx.intent.frame.editing_model, model)

        assert %{lifecycle: {:failed, _message, %StartRemedy{key_hint: ^hint}}} =
                 AgentChatBuilder.build(ctx)
      end
    end

    test "the notice headline is the lifecycle's own and the draft note names the bound new-session key" do
      session = fake_session_pid()
      request = StartRequest.default()
      saved = "Your draft is saved. SPC a S n starts a new session."

      for editing_model <- [:vim, :cua],
          {lifecycle, headline, note} <- [
            {{:conversation, session}, "", ""},
            {:starting, "Starting Agent", ""},
            {:unavailable, "No active Agent session", saved},
            {{:failed, StartFailure.timed_out(request)}, "Agent could not start", saved},
            {{:failed, StartFailure.session_crashed(self())}, "Agent session stopped", saved},
            {{:failed, StartFailure.session_crashed(remote_pid())}, "Agent session stopped",
             saved},
            {{:failed, StartFailure.missing_credentials()}, "Agent needs setup", saved}
          ] do
        ctx = context(session, synced_panel([]), lifecycle: lifecycle)
        ctx = put_in(ctx.intent.frame.editing_model, editing_model)

        assert %{lifecycle_headline: ^headline, draft_note: ^note} = AgentChatBuilder.build(ctx),
               "#{editing_model} #{inspect(lifecycle)}"
      end
    end

    test "the draft note is shown only where a composer is visible" do
      session = fake_session_pid()
      ctx = context(session, synced_panel([]), lifecycle: :unavailable)
      no_rows = put_in(ctx.prompt.projection.visible_rows, 0)

      assert %{draft_note: ""} = AgentChatBuilder.build(no_rows)

      assert %{lifecycle_headline: "Agent unavailable", draft_note: ""} =
               AgentChatBuilder.build(%{ctx | prompt: nil})
    end

    test "chat status needs the user only after a failed start" do
      session = fake_session_pid()
      failure = StartFailure.timed_out(StartRequest.default())
      errored = AgentState.set_error(%AgentState{}, "provider exploded")

      for {lifecycle, agent, status} <- [
            {:starting, %AgentState{}, :idle},
            {:unavailable, %AgentState{}, :idle},
            {{:failed, failure}, %AgentState{}, :needs_you},
            {{:failed, failure}, errored, :needs_you},
            {{:conversation, session}, errored, :error}
          ] do
        model =
          context(session, synced_panel([]), lifecycle: lifecycle, agent: agent)
          |> AgentChatBuilder.build()

        assert model.status == status, "#{inspect(lifecycle)} -> #{model.status}"
      end
    end

    test "the header never reads Resolving model after a failed start" do
      session = fake_session_pid()
      failure = StartFailure.timed_out(StartRequest.default())

      model =
        context(session, synced_panel([]), lifecycle: {:failed, failure})
        |> AgentChatBuilder.build()

      refute model.model_name =~ "Resolving"
    end
  end

  test "a missing composer has a reason instead of hiding the chat" do
    session = fake_session_pid()
    ctx = context(session, synced_panel([{:assistant, "ready"}]))

    assert %{visible?: true, lifecycle: :conversation} = AgentChatBuilder.build(ctx)

    assert %{
             visible?: true,
             lifecycle: {:failed, "The composer is unavailable." <> _, nil},
             prompt_visible_rows: 0
           } = AgentChatBuilder.build(%{ctx | prompt: nil})

    assert Process.info(session, :messages) == {:messages, []}
  end

  test "build/1 sends cached display message pairs to resident agent transcript" do
    session = fake_session_pid()
    old_message = {:assistant, "old pinned"}
    hidden_message = {:user, "hidden"}
    visible_message = {:assistant, "visible"}
    message_ids = [{101, old_message}, {102, hidden_message}, {103, visible_message}]

    panel =
      synced_panel([old_message, hidden_message, visible_message],
        display_start_index: 2,
        message_ids: message_ids,
        pinned_ids: MapSet.new([101]),
        styled_messages: [nil, nil, nil, nil]
      )

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert model.visible?

    summaries = Enum.map(model.resident_messages, &message_summary/1)

    assert [
             {101, :assistant, "old pinned"},
             {_, :system, "── pinned ──"},
             {_, :system, "── 2 earlier messages hidden ──"},
             {103, :assistant, "visible"},
             {_, :system, "Agent UI registry online"}
           ] = summaries

    refute {:user, "hidden"} in Enum.map(summaries, fn {_id, type, text} -> {type, text} end)
  end

  test "build/1 carries the composer input focus for transcript scroll gating (#2654)" do
    session = fake_session_pid()
    panel = synced_panel([{:assistant, "hi"}])

    focused = context(session, %{panel | input_focused: true}) |> AgentChatBuilder.build()
    unfocused = context(session, %{panel | input_focused: false}) |> AgentChatBuilder.build()

    assert focused.input_focused
    refute unfocused.input_focused
  end

  test "build/1 emits semantic assistant markdown blocks in resident transcript when cache has them" do
    session = fake_session_pid()

    blocks = [
      MarkdownBlock.code_block(123, "elixir", "Elixir", nil, true, [
        [{"IO.puts(:hi)", 0x98BE65, 0x21242B, 0x10}]
      ])
    ]

    panel =
      synced_panel([{:assistant, "```elixir\nIO.puts(:hi)\n```"}],
        styled_messages: [{:markdown_blocks, blocks}]
      )

    model =
      context(session, panel, theme: Theme.Fallback.theme())
      |> AgentChatBuilder.build()

    assert [{1, {:assistant_markdown, ^blocks}} | _] = model.resident_messages
  end

  test "build/1 keeps the full transcript resident for local frontend scrolling (#2654)" do
    session = fake_session_pid()

    panel =
      synced_panel(
        [
          {:assistant, "first"},
          {:assistant, "second"},
          {:assistant, "third"}
        ],
        scroll: Scroll.new(2) |> Scroll.update_metrics(5, 1),
        styled_messages: [nil, nil, nil]
      )

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert [
             {1, :assistant, "first"},
             {2, :assistant, "second"},
             {3, :assistant, "third"},
             {_, :system, "Agent UI registry online"}
           ] = Enum.map(model.resident_messages, &message_summary/1)

    # transcript_epoch is a stable, non-nil change token for the session.
    assert is_integer(model.transcript_epoch)
  end

  test "build/1 applies the configured resident byte cap and marks omitted messages" do
    options_server = start_supervised!({Options, name: nil})
    previous_options_server = Process.put(:minga_config_options, options_server)

    on_exit(fn ->
      if is_nil(previous_options_server) do
        Process.delete(:minga_config_options)
      else
        Process.put(:minga_config_options, previous_options_server)
      end
    end)

    session = fake_session_pid()
    panel = synced_panel([{:assistant, "first"}, {:assistant, "second"}])
    uncapped = context(session, panel) |> AgentChatBuilder.build()
    retained = Enum.take(uncapped.resident_messages, -2)

    retained_bytes =
      Enum.reduce(retained, 0, fn message, total ->
        total + AgentChatMessageCodec.resident_entry_size(message)
      end)

    assert :ok = Minga.Config.set(:agent_transcript_resident_max_bytes, retained_bytes)

    capped = context(session, panel) |> AgentChatBuilder.build()

    assert capped.resident_messages == retained
    assert capped.resident_truncated?
  end

  test "build/1 sends connect-provider empty state for first-run no-credential sessions" do
    session = fake_session_pid()

    panel =
      synced_panel([{:system, "Session started", :info}],
        empty_state: :credentials_missing
      )

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert [{_, :system, text}, {_, :system, "Agent UI registry online"}] =
             Enum.map(model.resident_messages, &message_summary/1)

    assert text =~ "Connect a provider"
    assert text =~ "/auth anthropic"
    assert text =~ "masked API key prompt"
    assert text =~ "/login"
    refute text =~ "Session started"
  end

  test "build/1 sends pick-model empty state for first-run sessions without a model" do
    session = fake_session_pid()
    panel = synced_panel([{:system, "Session started", :info}], empty_state: :no_model)

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert [{_, :system, text}, {_, :system, "Agent UI registry online"}] =
             Enum.map(model.resident_messages, &message_summary/1)

    assert text =~ "Pick a model"
    assert text =~ "/model"
    assert text =~ "SPC a S m"
    refute text =~ "Session started"
  end

  test "build/1 keeps normal first-run display for ready sessions" do
    session = fake_session_pid()
    panel = synced_panel([{:system, "Session started", :info}])

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert [{_, :system, "Session started"}, {_, :system, "Agent UI registry online"}] =
             Enum.map(model.resident_messages, &message_summary/1)
  end

  test "build/1 resolves tool calls with clean summaries and inline diff previews" do
    session = fake_session_pid()

    tool_call =
      ToolCall.new("tc-1", "edit_file", %{
        "path" => "lib/app.ex",
        "expected_revision" => "read-revision",
        "edits" => [%{"old_text" => "old", "new_text" => "new"}]
      })

    panel = synced_panel([{:tool_call, tool_call}], styled_messages: [nil])

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert {1, {:tool_call, view}} = List.first(model.resident_messages)
    assert view.name == "edit_file"
    assert view.summary == "lib/app.ex"
    assert view.preview_kind == :diff
    assert "file: lib/app.ex" in view.preview_lines
    assert "-old" in view.preview_lines
    assert "+new" in view.preview_lines
  end

  test "build/1 omits raw inspected preview lines for completed read-only tool calls" do
    session = fake_session_pid()

    read_only_calls = [
      {"read_file", %{"path" => "lib/app.ex"}, "lib/app.ex"},
      {"grep", %{"pattern" => "defmodule", "path" => "lib"}, "defmodule in lib"},
      {"find", %{"name" => "*.ex", "path" => "lib"}, "*.ex in lib"},
      {"list_directory", %{"path" => "lib"}, "lib"}
    ]

    panel =
      read_only_calls
      |> Enum.map(fn {name, args, _summary} ->
        {:tool_call, ToolCall.new("tc-#{name}", name, args) |> ToolCall.complete("ok")}
      end)
      |> synced_panel(styled_messages: List.duplicate(nil, Enum.count(read_only_calls)))

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    views = for {_id, {:tool_call, view}} <- model.resident_messages, do: view

    assert Enum.map(views, & &1.summary) ==
             Enum.map(read_only_calls, fn {_name, _args, summary} -> summary end)

    assert Enum.all?(views, &(&1.preview_lines == []))
  end

  test "build/1 uses captured write_file previews instead of recomputing current disk state" do
    session = fake_session_pid()
    path = "/tmp/minga-agent-chat-write-preview.txt"

    tool_call =
      ToolCall.new("tc-write", "write_file", %{"path" => path, "content" => "new\n"})
      |> ToolCall.set_preview(ToolApproval.build_file_diff_preview(path, "old\n", "new\n"))
      |> ToolCall.complete("wrote file")

    panel = synced_panel([{:tool_call, tool_call}], styled_messages: [nil])

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert {1, {:tool_call, view}} = List.first(model.resident_messages)
    assert view.name == "write_file"
    assert view.summary == path
    assert view.preview_kind == :diff
    assert "file: #{path}" in view.preview_lines
    assert "-old" in view.preview_lines
    assert "+new" in view.preview_lines
  end

  test "build/1 does not invent write_file transcript previews from current disk state" do
    session = fake_session_pid()
    path = "/tmp/minga-agent-chat-write-preview.txt"

    tool_call =
      ToolCall.new("tc-write", "write_file", %{"path" => path, "content" => "new\n"})
      |> ToolCall.complete("wrote file")

    panel = synced_panel([{:tool_call, tool_call}], styled_messages: [nil])

    model =
      context(session, panel)
      |> AgentChatBuilder.build()

    assert {1, {:tool_call, view}} = List.first(model.resident_messages)
    assert view.name == "write_file"
    assert view.summary == path
    assert view.preview_kind == :target
    assert view.preview_lines == []
  end

  test "build/1 projects a source-bound public approval without replacing its captured preview" do
    session = fake_session_pid()
    target = ApprovalTarget.new("session/会", "admitted-request/é", "tc/🛠")
    args = %{"path" => "lib/app.ex", "old_text" => "old", "new_text" => "new"}
    preview = Preview.new(:diff, "captured lib/app.ex", ["-captured old", "+captured new"])
    approval = PublicApproval.new(target, "edit_file", args, preview)
    pending = PendingApproval.new(session, approval)
    agent = AgentState.set_pending_approval(%AgentState{}, pending)
    tool_call = ToolCall.new(target.tool_call_id, approval.name, args)
    other = ToolCall.new("unrelated", "read_file", %{"path" => "README.md"})
    theme = Theme.Fallback.theme()

    for styled_messages <- [nil, [{:styled_lines, [[{"cached output", 0xBBC2CF, 0, 0}]]}]] do
      panel =
        synced_panel([{:tool_call, tool_call}, {:tool_call, other}],
          styled_messages: styled_messages
        )

      model = context(session, panel, agent: agent, theme: theme) |> AgentChatBuilder.build()

      assert [
               {1,
                {:approval_tool_call,
                 %ApprovalView{
                   name: "edit_file",
                   session_id: "session/会",
                   request_id: "admitted-request/é",
                   tool_call_id: "tc/🛠",
                   summary: "captured lib/app.ex",
                   preview_kind: :diff,
                   preview_lines: ["-captured old", "+captured new"]
                 }}},
               {2, {:tool_call, %ToolCallView{name: "read_file", summary: "README.md"}}}
               | _
             ] = model.resident_messages
    end
  end

  test "a tool Minga declined for lack of a folder is a declined card, never an error card" do
    # Both frontends draw the card from this model and decode the same wire byte.
    # Declined is an existing state (orange "Denied" on macOS and in the terminal); error is the red, failed one.
    line = "Minga has no folder to work in. Open a file or a folder."

    declined =
      "no-folder-call"
      |> ToolCall.new("read_file", %{"path" => "notes.txt"})
      |> ToolCall.deny(line)

    panel = synced_panel([{:tool_call, declined}])

    model =
      context(fake_session_pid(), panel, theme: Theme.Fallback.theme())
      |> AgentChatBuilder.build()

    assert [{1, {:tool_call, %ToolCallView{status: :denied, result: ^line} = card}} | _] =
             model.resident_messages

    assert <<0x04, 3, _rest::binary>> =
             AgentChatMessageCodec.encode_message_body({:tool_call, card})
  end

  test "a prompt declined by a read-only conversation is a calm row, never an error row" do
    # Both frontends draw the row from this model and decode the same level byte: 0 is the calm one, 1 the red one.
    declined =
      "Your draft was not sent and is preserved. This conversation can only be read here. " <>
        "Start a new conversation, or restore it in ~/code/api."

    panel = synced_panel([{:system, declined, :info}])

    model =
      context(fake_session_pid(), panel, theme: Theme.Fallback.theme())
      |> AgentChatBuilder.build()

    assert [{1, {:system, ^declined, :info} = row} | _] = model.resident_messages
    assert <<0x05, 0, _rest::binary>> = AgentChatMessageCodec.encode_message_body(row)

    # Nothing failed: the row alone does not put the conversation in the failed or needs-you state.
    # The session test asserts that its status is what it was before the prompt.
    refute model.status in [:error, :needs_you]
  end

  test "build/1 does not reactivate historical tool cards when a request reuses a tool ID" do
    session = fake_session_pid()
    target = ApprovalTarget.new("session-A", "new-admitted-request", "reused-tool-id")
    args = %{"command" => "echo current"}
    preview = Preview.new(:command, "echo current", ["echo current"])
    approval = PublicApproval.new(target, "shell", args, preview)

    agent =
      AgentState.set_pending_approval(%AgentState{}, PendingApproval.new(session, approval))

    completed =
      ToolCall.new(target.tool_call_id, "shell", %{"command" => "echo old"})
      |> ToolCall.complete("old output")

    rejected =
      ToolCall.new(target.tool_call_id, "shell", %{"command" => "echo denied"})
      |> ToolCall.error("denied")

    abandoned = ToolCall.new(target.tool_call_id, "shell", %{"command" => "echo abandoned"})

    current = ToolCall.new(target.tool_call_id, "shell", args)
    theme = Theme.Fallback.theme()

    panel =
      synced_panel([
        {:tool_call, abandoned},
        {:tool_call, completed},
        {:tool_call, rejected},
        {:tool_call, current}
      ])

    model = context(session, panel, agent: agent, theme: theme) |> AgentChatBuilder.build()

    assert [
             {1, {:tool_call, %ToolCallView{status: :running}}},
             {2, {:tool_call, %ToolCallView{status: :complete, result: "old output"}}},
             {3, {:tool_call, %ToolCallView{status: :error, result: "denied", is_error: true}}},
             {4,
              {:approval_tool_call,
               %ApprovalView{
                 session_id: "session-A",
                 request_id: "new-admitted-request",
                 tool_call_id: "reused-tool-id",
                 summary: "echo current"
               }}}
             | _
           ] = model.resident_messages
  end

  test "a retained output offer survives unrelated streaming but not a conversation change" do
    session = fake_session_pid()

    connection = fn epoch ->
      %ConnectionSnapshot{
        target: ConnectionTarget.new(session, "retained-offer", nil, epoch),
        credential_readiness: :checking,
        model_selection: nil,
        provider_phase: :stopped,
        operation: :idle,
        problem: nil
      }
    end

    {:ok, token} = Reference.token("retained-offer", String.duplicate("a", 32))

    {:ok, reference} =
      Reference.new(
        token: token,
        media_type: "text/plain",
        bytes: 7,
        sha256: Reference.digest("content")
      )

    {:ok, range} = Range.new(:full, :bytes, 0, 7, 7)
    {:ok, output} = Output.new("", :complete, range, reference: reference)
    tool = ToolCall.new("retained", "shell", %{}) |> ToolCall.complete("", output)
    preview_only = ToolCall.new("preview", "shell", %{}) |> ToolCall.complete("preview")
    messages = [{:tool_call, tool}, {:tool_call, preview_only}]
    connection = connection.(make_ref())
    source = SourceTranscript.new(messages, ~U[2026-01-01 00:00:00Z], make_ref())
    {:snapshot, snapshot} = SourceTranscript.since(source, :snapshot)
    style = {nil, %{}, fn _message, _id, _syntax -> nil end}

    projection =
      TranscriptProjection.replace(
        TranscriptProjection.new(),
        snapshot.entries,
        snapshot.pinned_ids,
        snapshot.cursor,
        style
      )

    panel = Panel.install_transcript(Panel.new(), projection, :keep)

    assert [
             {1, {:tool_call, %ToolCallView{retained_output_offer: <<_::128>> = offer} = card}},
             {2, {:tool_call, %ToolCallView{retained_output_offer: nil}}}
             | _
           ] =
             context(session, panel, connection: connection)
             |> AgentChatBuilder.build()
             |> Map.fetch!(:resident_messages)

    assert <<0x0B, ^offer::binary-size(16), _::binary>> =
             AgentChatMessageCodec.encode_message_body({:tool_call, card})

    source = SourceTranscript.append(source, {:assistant, "Streaming"})
    assert {:changes, changes} = SourceTranscript.since(source, snapshot.cursor)

    {streaming_projection, :follow} =
      TranscriptProjection.apply_changes(projection, changes, :follow, style)

    streaming =
      context(session, Panel.install_transcript(panel, streaming_projection, :keep),
        connection: connection
      )
      |> AgentChatBuilder.build()

    assert [{1, {:tool_call, %ToolCallView{retained_output_offer: ^offer}}} | _] =
             streaming.resident_messages

    replacement = SourceTranscript.new(messages, ~U[2026-01-01 00:00:00Z], make_ref())
    {:snapshot, snapshot} = SourceTranscript.since(replacement, :snapshot)

    changed_projection =
      TranscriptProjection.replace(
        streaming_projection,
        snapshot.entries,
        snapshot.pinned_ids,
        snapshot.cursor,
        style
      )

    changed =
      context(session, Panel.install_transcript(panel, changed_projection, :keep),
        connection: connection
      )
      |> AgentChatBuilder.build()

    assert [
             {1, {:tool_call, %ToolCallView{retained_output_offer: <<_::128>> = changed_offer}}}
             | _
           ] =
             changed.resident_messages

    refute changed_offer == offer
  end

  test "build/1 removes resolved controls without changing the tool card's stable message ID" do
    session = fake_session_pid()
    target = ApprovalTarget.new("session-A", "admitted-request", "tc-shell")
    args = %{"command" => "echo hello"}
    preview = Preview.new(:command, "echo hello", ["echo hello"])
    approval = PublicApproval.new(target, "shell", args, preview)

    agent =
      AgentState.set_pending_approval(%AgentState{}, PendingApproval.new(session, approval))

    tool_call = ToolCall.new(target.tool_call_id, "shell", args) |> ToolCall.set_preview(preview)
    message = {:tool_call, tool_call}
    panel = synced_panel([message], message_ids: [{42, message}])
    pending = context(session, panel, agent: agent) |> AgentChatBuilder.build()

    assert [{42, {:approval_tool_call, %ApprovalView{}}} | _] = pending.resident_messages

    failure = StartFailure.timed_out(StartRequest.default())

    for {phase, presented} <- [
          {:starting, :starting},
          {{:failed, failure}, {:failed, failure.message, @retry_remedy}},
          {:unavailable, :unavailable}
        ] do
      model =
        context(session, panel, agent: agent, lifecycle: phase, draft: "Unsent draft café")
        |> AgentChatBuilder.build()

      assert model.visible?
      assert model.lifecycle == presented
      assert model.prompt == "Unsent draft café"
      refute Enum.any?(model.resident_messages, &match?({_, {:approval_tool_call, _}}, &1))
    end

    resolved_agent = AgentState.clear_approval(agent, target, session)

    for resolved_tool <- [
          tool_call,
          ToolCall.complete(tool_call, "hello"),
          ToolCall.error(tool_call, "denied")
        ] do
      message = {:tool_call, resolved_tool}
      panel = synced_panel([message], message_ids: [{42, message}])
      model = context(session, panel, agent: resolved_agent) |> AgentChatBuilder.build()

      assert [{42, {:tool_call, %ToolCallView{} = view}} | _] = model.resident_messages
      assert view.status == resolved_tool.status
      assert view.result == resolved_tool.result
      assert view.is_error == resolved_tool.is_error
      assert view.preview_kind == :command
      assert view.preview_lines == ["echo hello"]
      refute Enum.any?(model.resident_messages, &match?({_, {:approval_tool_call, _}}, &1))
    end
  end

  describe "streamed transcript transfer" do
    test "a streamed text batch sends only the changed tail entry within the epoch" do
      frame = streamed_frame(100)

      # Entries after the revised tail are resent unchanged; history is not.
      assert %{mode: 1, trim_front: 0, base_count: 100} = frame
      assert frame.epoch == frame.seed_epoch
      assert [{101, body} | _enrichments] = frame.entries
      assert body == AgentChatMessageCodec.encode_message_body({:assistant, "Streaming reply"})
    end

    test "streamed frame bytes do not grow with retained transcript length" do
      small = streamed_frame(100)
      large = streamed_frame(10_000)

      assert %{mode: 1, base_count: 10_000} = large
      assert large.count == small.count
      assert large.seed_bytes > 100 * small.seed_bytes / 2
      assert byte_size(large.frame) == byte_size(small.frame)
    end
  end

  # Seeds a resident transcript of `history` user entries plus a streaming
  # assistant tail, then applies one streamed text batch the way
  # StreamEventWorkflow does and encodes the following frame.
  defp streamed_frame(history) do
    session = fake_session_pid()
    style = {nil, %{}, fn _message, _id, _syntax -> nil end}
    turns = Enum.map(1..history, &{:user, "turn #{&1}"})

    source =
      turns
      |> SourceTranscript.new(~U[2026-01-01 00:00:00Z], make_ref())
      |> SourceTranscript.append({:assistant, "Streaming"})

    {:snapshot, snapshot} = SourceTranscript.since(source, :snapshot)

    projection =
      TranscriptProjection.replace(
        TranscriptProjection.new(),
        snapshot.entries,
        snapshot.pinned_ids,
        snapshot.cursor,
        style
      )

    panel = Panel.install_transcript(Panel.new(), projection, :keep)
    seed_model = session |> context(panel) |> AgentChatBuilder.build()
    {seed, caches} = AgentTranscriptEncoder.encode(seed_model, Caches.new())
    assert %{mode: 0, count: count} = decode_transcript(seed)
    # Registry transcript enrichments may follow the conversation entries.
    assert count >= history + 1

    streamed = SourceTranscript.append_stream_tail(source, :assistant, [" reply"])
    {:changes, changes} = SourceTranscript.since(streamed, snapshot.cursor)

    {streamed_projection, :follow} =
      TranscriptProjection.apply_changes(projection, changes, :follow, style)

    streamed_panel =
      panel
      |> Panel.install_transcript(streamed_projection, :keep)
      |> Panel.bump_message_version()

    model = session |> context(streamed_panel) |> AgentChatBuilder.build()
    {frame, _caches} = AgentTranscriptEncoder.encode(model, caches)

    frame
    |> decode_transcript()
    |> Map.merge(%{
      frame: frame,
      seed_bytes: byte_size(seed),
      seed_epoch: seed_model.transcript_epoch
    })
  end

  defp decode_transcript(<<_op, len::32, payload::binary-size(len)>>) do
    <<1, mode, epoch::32, _truncated, rest::binary>> = payload

    {header, rest} =
      case {mode, rest} do
        {0, <<count::32, rest::binary>>} ->
          {%{trim_front: 0, base_count: 0, count: count}, rest}

        {1, <<trim::32, base::32, count::32, rest::binary>>} ->
          {%{trim_front: trim, base_count: base, count: count}, rest}
      end

    entries =
      for <<id::32, body_len::32, body::binary-size(body_len) <- rest>>, do: {id, body}

    Map.merge(header, %{mode: mode, epoch: epoch, entries: entries})
  end

  defp message_summary({id, {:assistant, text}}), do: {id, :assistant, text}
  defp message_summary({id, {:system, text, _level}}), do: {id, :system, text}
  defp message_summary({id, {:user, text}}), do: {id, :user, text}
  defp message_summary({id, {kind, _, _}}), do: {id, kind, nil}

  defp remote_pid do
    node = "remote@host"
    :erlang.binary_to_term(<<131, 88, 119, byte_size(node), node::binary, 1::32, 0::32, 1::32>>)
  end

  defp synced_panel(messages, opts \\ []) do
    projection = TranscriptFixture.projection(messages, opts)

    Panel.new()
    |> Panel.install_transcript(projection, :keep)
    |> maybe_set_panel_scroll(Keyword.get(opts, :scroll))
  end

  defp maybe_set_panel_scroll(panel, nil), do: panel
  defp maybe_set_panel_scroll(panel, scroll), do: Panel.set_scroll(panel, scroll)

  defp context(session, panel, opts \\ []) do
    tab = Tab.new_agent(1, "Agent")
    {tab_bar, workspace} = TabBar.add_workspace(TabBar.new(tab), "Agent", session)
    tab_bar = TabBar.move_tab_to_workspace(tab_bar, tab.id, workspace.id)
    window = Window.new_agent_chat(1, 24, 80)

    state = TestHelpers.base_state(port_manager: nil)

    agent_ui =
      %UIState{panel: panel}
      |> PromptBuffer.ensure()
      |> PromptBuffer.insert_char(Keyword.get(opts, :draft, ""))
      |> UIState.restore_chat(Keyword.get(opts, :lifecycle, {:conversation, session}))

    agent_ui =
      case Keyword.fetch(opts, :connection) do
        {:ok, connection} -> UIState.project_connection(agent_ui, connection)
        :error -> agent_ui
      end

    windows = Windows.set_map(state.workspace.windows, %{1 => window})

    workspace =
      state.workspace
      |> SessionState.set_windows(windows)
      |> SessionState.set_buffers(Buffers.set_active_override(state.workspace.buffers, nil))
      |> SessionState.set_agent_ui(agent_ui)
      |> SessionState.set_keymap_scope(:agent)

    shell = TraditionalState.install_tab_bar(state.shell_runtime.state, tab_bar)
    agent = Keyword.get(opts, :agent, TraditionalState.agent(shell))
    shell = TraditionalState.replace_agent(shell, agent)

    state = %{
      state
      | workspace: workspace,
        appearance:
          Appearance.select_theme(
            state.appearance,
            Keyword.get(opts, :theme, state.appearance.theme)
          )
    }

    # Capture live status before attaching the identity-only session for Content and emit.
    input = state |> Input.from_editor_state() |> Layout.put()
    frame = %{input.intent.frame | shell_state: shell}
    intent = admit_seed(%{input.intent | frame: frame}, panel.transcript)
    input = %{input | intent: intent, workspace: intent.workspace}
    {[_content], _cursor, input} = Content.build_agent_chat_content(input, Layout.get(input))
    Context.from_input(input)
  end

  # The renderer admits the transcript with the same intent that carries its decorations.
  defp admit_seed(intent, projection) do
    {:ok, root} = AgentChatBuilder.admit(nil, TranscriptUpdate.seed(projection, 0), intent)
    Intent.with_agent_transcript(intent, root)
  end

  defp fake_session_pid do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end
end
