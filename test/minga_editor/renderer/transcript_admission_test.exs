defmodule MingaEditor.Renderer.TranscriptAdmissionTest do
  @moduledoc """
  Ordered Editor-to-Renderer transcript admission through a real `Renderer.Server`.

  The stub pipeline reports the resident transcript each attempt carries, so these tests observe which root a frame renders without a frontend.
  """

  use ExUnit.Case, async: true

  alias MingaAgent.Session.Transcript, as: Source
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Public, as: PublicApproval
  alias MingaAgent.ToolApproval.Target, as: ApprovalTarget
  alias MingaAgent.ToolCall
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.RenderModel.UI.AgentChatResident
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.Renderer.Server
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Render

  @context {nil, %{}, &__MODULE__.style/3}

  @doc false
  @spec style(term(), pos_integer(), map()) :: term()
  def style(_message, _id, _syntax), do: nil

  setup do
    session = spawn_session()
    source = Source.new(messages(), ~U[2026-01-01 00:00:00Z], make_ref())
    {:snapshot, snapshot} = Source.since(source, :snapshot)

    projection =
      TranscriptProjection.replace(
        TranscriptProjection.new(),
        snapshot.entries,
        snapshot.pinned_ids,
        snapshot.cursor,
        @context
      )

    target = ApprovalTarget.new("session", "request", "tool-1")
    preview = Preview.new(:command, "echo", ["echo"])
    approval = PublicApproval.new(target, "shell", %{}, preview)

    editor =
      TestHelpers.base_state(filetype: :text)
      |> with_transcript(session, projection)
      |> with_approval(PendingApproval.new(session, approval))

    %{
      editor: editor,
      session: session,
      source: source,
      projection: projection,
      render: Render.connect_renderer(Render.new(), self())
    }
  end

  test "a superseding composer frame renders the uncommitted middle revision; the in-flight frame keeps its root and controls",
       ctx do
    renderer = start_renderer()
    {generation, 0} = Server.acknowledgement_state(renderer)

    {render, frame_a} = submit(ctx.render, ctx.editor)
    assert {:seed, _, 1, _, _} = frame_a.transcript
    Server.cast_snapshot(renderer, frame_a, 1)
    assert_receive {:presented, 1, ^generation, false, presented_a}, 1_000
    assert {2, :approval} in presented_a

    # B: the middle tool completes and its approval resolves.
    {_source_b, projection_b} = revise_tool(ctx.source, ctx.projection)

    editor_b =
      ctx.editor
      |> with_transcript(ctx.session, projection_b)
      |> with_approval(nil)

    {render, frame_b} = submit(render, editor_b)
    assert {:changes, _, 1, 2, _, [{:put, {3, 1}, _item}]} = frame_b.transcript

    # C: a composer-only frame carries no transcript change.
    {_render, frame_c} = submit(render, editor_b)
    assert {:unchanged, _, 2, _} = frame_c.transcript
    assert :erts_debug.flat_size(frame_c) < :erts_debug.flat_size(frame_a)

    Server.cast_snapshot(renderer, frame_b, 2)
    Server.cast_snapshot(renderer, frame_c, 3)

    retained = :sys.get_state(renderer)
    assert {:awaiting_ack, lease, %FrameAttempt{seq: 3} = successor} = retained.frame_credit
    assert {2, :approval} in summary(lease.attempt.intent)
    assert {2, {:tool_call, :complete}} in summary(successor.intent)
    refute {2, :approval} in summary(successor.intent)

    Server.frame_status(renderer, {:frame_applied, generation, 1})
    assert_receive {:presented, 3, ^generation, false, presented_c}, 1_000
    refute_receive {:presented, 2, _, _, _}, 0
    assert {2, {:tool_call, :complete}} in presented_c
  end

  test "a retried attempt renders its own root; a rejection with a queued successor renders the successor",
       ctx do
    renderer = start_renderer()
    {generation, 0} = Server.acknowledgement_state(renderer)
    {render, frame_a} = submit(ctx.render, ctx.editor)
    Server.cast_snapshot(renderer, frame_a, 1)
    assert_receive {:presented, 1, ^generation, false, presented_a}, 1_000

    Server.frame_status(
      renderer,
      {:frame_rejected, generation, 1, 0, :base_sequence_mismatch, :retryable_recovery}
    )

    assert_receive {:presented, retry_seq, retry_generation, true, ^presented_a}, 1_000
    assert retry_generation > generation

    {_source, projection_b} = revise_tool(ctx.source, ctx.projection)
    editor_b = ctx.editor |> with_transcript(ctx.session, projection_b) |> with_approval(nil)
    {_render, frame_b} = submit(render, editor_b)
    Server.cast_snapshot(renderer, frame_b, retry_seq + 1)

    Server.frame_status(
      renderer,
      {:frame_rejected, retry_generation, retry_seq, 0, :base_sequence_mismatch,
       :retryable_recovery}
    )

    assert_receive {:presented, _seq, _generation, true, presented_b}, 1_000
    assert {2, {:tool_call, :complete}} in presented_b
    refute {2, :approval} in presented_b
  end

  test "frontend recovery keeps the resident root while renderer replacement reseeds from the Editor",
       ctx do
    {render, frame_a} = submit(ctx.render, ctx.editor)

    {receiver, _intent, :admitted} =
      RendererState.receive_submission(RendererState.new([]), frame_a)

    root = receiver.agent_transcript
    assert %AgentChatResident{} = root

    # A frontend reset clears its committed base, not the renderer's root.
    reset = RendererState.reset_frontend(receiver, 7)
    assert reset.agent_transcript === root
    assert reset.caches.adapter_gui_caches.last_agent_transcript.fp == nil

    # A restarted renderer has no base: a change list is rejected without mutation.
    {_source_b, projection_b} = revise_tool(ctx.source, ctx.projection)
    editor_b = with_transcript(ctx.editor, ctx.session, projection_b)
    {render, frame_b} = submit(render, editor_b)

    {fresh, fresh_intent, :reseed_required} =
      RendererState.receive_submission(RendererState.new([]), frame_b)

    assert fresh.agent_transcript == nil
    assert Intent.agent_transcript(fresh_intent) == nil

    # A cross-generation update is rejected and the last good root stays installed.
    assert {:changes, _identity, 1, 2, _epoch, _changes} = frame_b.transcript
    foreign_frame = %{frame_b | transcript: put_elem(frame_b.transcript, 1, make_ref())}

    {kept, kept_intent, :reseed_required} =
      RendererState.receive_submission(receiver, foreign_frame)

    assert kept.agent_transcript === root
    assert Intent.agent_transcript(kept_intent) === root

    # The Editor answers a reseed request for its connected renderer with a seed.
    reseeded = Render.require_transcript_seed(render, self())
    {_render, seed} = submit(reseeded, editor_b)
    assert {:seed, _, revision, _, _} = seed.transcript
    assert revision > 2

    # A replacement renderer generation also starts from a seed.
    replacement = spawn(fn -> :ok end)
    {_render, replaced} = render |> Render.connect_renderer(replacement) |> submit(editor_b)
    assert {:seed, _, _, _, _} = replaced.transcript
  end

  test "a seed for another presentation with an unencodable entry installs that presentation with a fallback body",
       ctx do
    {render, frame_a} = submit(ctx.render, ctx.editor)

    {receiver, _intent, :admitted} =
      RendererState.receive_submission(RendererState.new([]), frame_a)

    assert {2, :approval} in summary_of(receiver.agent_transcript)

    # Tab B: a different presentation whose only tool call cannot be encoded.
    source_b =
      Source.new(
        [{:user, "other tab"}, {:tool_call, oversized_tool("tool-1")}],
        ~U[2026-01-01 00:00:00Z],
        make_ref()
      )

    {:snapshot, snapshot} = Source.since(source_b, :snapshot)

    projection_b =
      TranscriptProjection.replace(
        TranscriptProjection.new(),
        snapshot.entries,
        snapshot.pinned_ids,
        snapshot.cursor,
        @context
      )

    {_render, seed_b} = submit(render, with_transcript(ctx.editor, ctx.session, projection_b))
    assert {:seed, identity_b, _, _, _} = seed_b.transcript

    {installed, intent, admission} = RendererState.receive_submission(receiver, seed_b)
    assert {:admitted, _fallbacks} = normalize(admission)
    root = Intent.agent_transcript(intent)
    assert root === installed.agent_transcript
    assert root.identity == identity_b

    assert [{1, {:user, "other tab"}}, {2, {:system, fallback, :error}} | _footer] =
             root |> AgentChatResident.resident_messages() |> elem(0)

    assert fallback =~ "too large to display"
    refute Enum.any?(summary_of(root), &match?({_, :approval}, &1))
    refute {3, :assistant} in summary_of(root)
  end

  test "an unencodable changed entry admits a fallback and later frames stay contiguous", ctx do
    renderer = start_renderer(require_ack?: false)
    {render, frame_a} = submit(ctx.render, ctx.editor)
    Server.cast_snapshot(renderer, frame_a, 1)
    assert_receive {:presented, 1, _, _, _}, 1_000

    source =
      Source.update_at(ctx.source, 1, fn {:tool_call, _call} ->
        {:tool_call, oversized_tool("tool-1")}
      end)

    {:changes, changes} = Source.since(source, ctx.projection.source_cursor)

    {projection, _} =
      TranscriptProjection.apply_changes(ctx.projection, changes, :follow, @context)

    editor_b = with_transcript(ctx.editor, ctx.session, projection)
    {render, invalid} = submit(render, editor_b)
    assert {:changes, _, 1, 2, _, _} = invalid.transcript
    Server.cast_snapshot(renderer, invalid, 2)
    assert_receive {:presented, 2, _, _, presented}, 1_000
    assert {2, :system} in presented

    # Composer-only and further transcript frames stay contiguous with the Editor base.
    {render, unchanged} = submit(render, editor_b)
    assert {:unchanged, _, 2, _} = unchanged.transcript
    Server.cast_snapshot(renderer, unchanged, 3)

    source = Source.append(source, {:assistant, "after"})
    {:changes, more} = Source.since(source, projection.source_cursor)
    {projection, _} = TranscriptProjection.apply_changes(projection, more, :follow, @context)
    {_render, next} = submit(render, with_transcript(ctx.editor, ctx.session, projection))
    assert {:changes, _, 2, 3, _, _} = next.transcript
    Server.cast_snapshot(renderer, next, 4)

    assert_receive {:presented, 3, _, _, _}, 1_000
    assert_receive {:presented, 4, _, _, after_append}, 1_000
    assert {2, :system} in after_append
    assert {4, :assistant} in after_append
    assert :sys.get_state(renderer).agent_transcript.revision == 3
    refute_received {:renderer_transcript_reseed, _}
  end

  test "an entry that stays unencodable is reported once, not on every frame", ctx do
    {render, frame_a} = submit(ctx.render, ctx.editor)

    {receiver, _intent, :admitted} =
      RendererState.receive_submission(RendererState.new([]), frame_a)

    source =
      Source.update_at(ctx.source, 1, fn {:tool_call, _call} ->
        {:tool_call, oversized_tool("tool-1")}
      end)

    {:changes, changes} = Source.since(source, ctx.projection.source_cursor)

    {projection, _} =
      TranscriptProjection.apply_changes(ctx.projection, changes, :follow, @context)

    editor_b = with_transcript(ctx.editor, ctx.session, projection)
    {render, invalid} = submit(render, editor_b)
    {receiver, _, first} = RendererState.receive_submission(receiver, invalid)
    assert {:admitted, [{3, 1}]} = normalize(first)

    Enum.reduce(1..3, {render, receiver}, fn _frame, {render, receiver} ->
      {render, unchanged} = submit(render, editor_b)
      {receiver, _, admission} = RendererState.receive_submission(receiver, unchanged)
      assert admission == :admitted
      {render, receiver}
    end)
  end

  test "a rejected update asks the submitting Editor for a seed", ctx do
    renderer = start_renderer(require_ack?: false)
    {_source_b, projection_b} = revise_tool(ctx.source, ctx.projection)
    {render, _seed} = submit(ctx.render, ctx.editor)
    {_render, delta} = submit(render, with_transcript(ctx.editor, ctx.session, projection_b))
    assert {:changes, _, _, _, _, _} = delta.transcript

    Server.cast_snapshot(renderer, delta, 1)
    assert_receive {:renderer_transcript_reseed, ^renderer}, 1_000
    assert_receive {:presented, 1, _generation, _keyframe?, []}, 1_000
  end

  defp submit(render, editor),
    do:
      Render.prepare_submission(
        render,
        Intent.from_editor_state(editor),
        editor.lsp.semantic_token_revisions
      )

  defp messages do
    [
      {:user, "question"},
      {:tool_call, ToolCall.new("tool-1", "shell", %{})},
      {:assistant, "answer"}
    ]
  end

  defp revise_tool(source, projection) do
    source =
      Source.update_at(source, 1, fn {:tool_call, call} ->
        {:tool_call, ToolCall.complete(call, "done")}
      end)

    {:changes, changes} = Source.since(source, projection.source_cursor)

    {projection, _reading} =
      TranscriptProjection.apply_changes(projection, changes, :follow, @context)

    {source, projection}
  end

  defp with_transcript(editor, session, projection) do
    agent_ui =
      case editor.workspace.agent_ui do
        %UIState{panel: %Panel{prompt_buffer: pid}} = ui when is_pid(pid) -> ui
        _other -> PromptBuffer.ensure(%UIState{panel: Panel.new()})
      end

    panel = Panel.install_transcript(agent_ui.panel, projection, :keep)
    agent_ui = UIState.transition_chat(%{agent_ui | panel: panel}, {:conversation, session})

    %{editor | workspace: SessionState.set_agent_ui(editor.workspace, agent_ui)}
  end

  defp with_approval(editor, pending) do
    shell = Runtime.state(editor.shell_runtime)
    agent = TraditionalState.agent(shell)

    agent =
      case pending do
        nil -> AgentState.clear_pending_approval(agent)
        pending -> AgentState.set_pending_approval(agent, pending)
      end

    shell = TraditionalState.replace_agent(shell, agent)
    %{editor | shell_runtime: Runtime.install_traditional_state(editor.shell_runtime, shell)}
  end

  defp summary(%Intent{} = intent) do
    case Intent.agent_transcript(intent) do
      %AgentChatResident{} = root ->
        root |> AgentChatResident.resident_messages() |> elem(0) |> Enum.map(&message_summary/1)

      nil ->
        []
    end
  end

  defp oversized_tool(id), do: ToolCall.new(id, String.duplicate("n", 70_000), %{})

  defp summary_of(root),
    do: root |> AgentChatResident.resident_messages() |> elem(0) |> Enum.map(&message_summary/1)

  defp normalize(:admitted), do: {:admitted, []}
  defp normalize({:admitted, keys}), do: {:admitted, keys}
  defp normalize(other), do: other

  defp message_summary({id, {:approval_tool_call, _view}}), do: {id, :approval}
  defp message_summary({id, {:tool_call, view}}), do: {id, {:tool_call, view.status}}
  defp message_summary({id, {kind, _}}), do: {id, kind}
  defp message_summary({id, {kind, _, _}}), do: {id, kind}

  defp start_renderer(opts \\ []) do
    parent = self()

    pipeline = fn input ->
      send(
        parent,
        {:presented, input.frame_seq, input.caches.recovery_generation,
         input.intent.frame.force_keyframe?, summary(input.intent)}
      )

      %{input | caches: %{input.caches | last_emitted_frame_seq: input.frame_seq}}
    end

    start_supervised!(
      {Server,
       Keyword.merge(
         [
           name: nil,
           editor_pid: self(),
           pipeline: pipeline,
           require_ack?: true,
           ack_timeout_ms: 60_000,
           recovery_reserver: fn -> {System.unique_integer([:positive, :monotonic]), 1} end
         ],
         opts
       )}
    )
  end

  defp spawn_session do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(pid, :stop) end)
    pid
  end
end
