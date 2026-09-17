defmodule MingaEditor.Renderer.SubmissionTest do
  use ExUnit.Case, async: true

  alias Minga.Language.Highlight.Span
  alias Minga.Parser.EventCorrelation
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Renderer.FrameAttempt
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.Renderer.Server
  alias MingaEditor.Renderer.Submission
  alias MingaEditor.Renderer.RenderReceipt
  alias Minga.Perf.ProductionGate
  alias MingaEditor.State.{Highlighting, LSP, Parser, Render}
  alias MingaEditor.UI.Face.Registry
  alias MingaEditor.UI.{Highlight, Theme}

  setup do
    editor = TestHelpers.base_state(filetype: :text)
    buffer = editor.workspace.buffers.active

    highlight =
      Highlight.new()
      |> Highlight.put_names(["keyword"])
      |> Highlight.put_spans(1, [Span.new(0, 4, 0)])

    editor = put_highlight(editor, buffer, highlight)

    editor = %{
      editor
      | lsp:
          LSP.accept_semantic_tokens(editor.lsp, buffer, 1, ["@lsp.type.variable"], [
            Span.new(5, 8, 0)
          ])
    }

    %{
      editor: editor,
      buffer: buffer,
      highlight: highlight,
      render: Render.connect_renderer(Render.new(), self())
    }
  end

  test "full and unchanged delta restore the exact same complete intent", %{
    editor: editor,
    render: render
  } do
    intent = Intent.from_editor_state(editor)
    {render, first} = submit(render, editor)
    {renderer, restored} = RendererState.receive_submission(RendererState.new([]), first)
    assert restored == intent

    {_render, unchanged} = submit(render, editor)
    {next, restored} = RendererState.receive_submission(renderer, unchanged)
    assert restored == intent
    assert next.highlights == renderer.highlights
    assert next.semantic_tokens == renderer.semantic_tokens
    assert :erts_debug.flat_size(unchanged) < :erts_debug.flat_size(first)
  end

  test "unchanged submission cost and payload do not grow with span count", %{
    editor: editor,
    buffer: buffer
  } do
    measurements =
      for count <- [10, 40_000] do
        spans = Enum.map(0..(count - 1), &Span.new(&1 * 4, &1 * 4 + 3, 0))

        highlight =
          Highlight.new() |> Highlight.put_names(["keyword"]) |> Highlight.put_spans(1, spans)

        editor = put_highlight(editor, buffer, highlight)

        editor = %{
          editor
          | lsp: LSP.accept_semantic_tokens(editor.lsp, buffer, 1, ["@lsp.type.variable"], spans)
        }

        intent = Intent.from_editor_state(editor)

        {render, _full} =
          Render.prepare_submission(editor.render, intent, editor.lsp.semantic_token_revisions)

        {_, warm} = Render.prepare_submission(render, intent, editor.lsp.semantic_token_revisions)
        {:reductions, before} = Process.info(self(), :reductions)

        for _ <- 1..100,
            do: Render.prepare_submission(render, intent, editor.lsp.semantic_token_revisions)

        {:reductions, after_count} = Process.info(self(), :reductions)
        {:erts_debug.flat_size(warm), after_count - before}
      end

    [{small_size, small_work}, {large_size, large_work}] = measurements
    assert large_size == small_size
    assert large_work <= small_work * 2
  end

  test "every syntax change arrives without a document-version change", %{
    editor: editor,
    buffer: buffer,
    highlight: highlight,
    render: render
  } do
    {render, first} = submit(render, editor)
    {receiver, _} = RendererState.receive_submission(RendererState.new([]), first)
    correlation = EventCorrelation.new(make_ref(), 1)

    changes = [
      Highlight.put_names(highlight, ["function"]),
      Highlight.retheme(highlight, Theme.get!(:one_light)),
      Highlight.with_face_registry(
        highlight,
        Registry.from_syntax(%{"keyword" => [fg: 0x123456]})
      ),
      Highlight.correlate(highlight, correlation),
      Highlight.put_spans(highlight, 1, [Span.new(1, 5, 0)])
    ]

    for changed <- changes do
      updated = put_highlight(editor, buffer, changed)
      {_render, submission} = submit(render, updated)
      {_receiver, restored} = RendererState.receive_submission(receiver, submission)
      assert restored.frame.highlighting.highlights[buffer] == changed
      assert restored.frame.semantic_tokens == editor.lsp.semantic_tokens
    end
  end

  test "accepted semantic updates at the same version and clearing are independent of syntax", %{
    editor: editor,
    buffer: buffer,
    render: render
  } do
    {render, first} = submit(render, editor)
    {receiver, _} = RendererState.receive_submission(RendererState.new([]), first)

    updated = %{
      editor
      | lsp:
          LSP.accept_semantic_tokens(editor.lsp, buffer, 1, ["@lsp.type.function"], [
            Span.new(1, 7, 0)
          ])
    }

    {render, change} = submit(render, updated)
    {receiver, restored} = RendererState.receive_submission(receiver, change)
    assert restored.frame.semantic_tokens == updated.lsp.semantic_tokens
    assert restored.frame.highlighting == editor.parser.highlighting

    cleared = %{updated | lsp: LSP.clear_semantic_tokens(updated.lsp, buffer)}
    {_render, removal} = submit(render, cleared)
    {receiver, restored} = RendererState.receive_submission(receiver, removal)
    assert receiver.semantic_tokens == %{}
    assert restored.frame.semantic_tokens == %{}
    assert restored.frame.highlighting == editor.parser.highlighting
  end

  test "closed buffers are removed from retained maps without rewriting existing attempts", %{
    editor: editor,
    buffer: buffer,
    render: render
  } do
    {render, first} = submit(render, editor)
    {receiver, original} = RendererState.receive_submission(RendererState.new([]), first)
    current = FrameAttempt.new(original, 1, 0)
    receiver = RendererState.schedule_frame(receiver, current, make_ref())

    closed = %{
      editor
      | parser:
          Parser.accept_highlighting(
            editor.parser,
            Highlighting.remove_buffer(editor.parser.highlighting, buffer)
          ),
        lsp: LSP.retire_buffer(editor.lsp, buffer)
    }

    {_render, removal} = submit(render, closed)
    {receiver, restored} = RendererState.receive_submission(receiver, removal)
    assert receiver.highlights == %{}
    assert receiver.semantic_tokens == %{}
    assert restored.frame.highlighting.highlights == %{}
    assert restored.frame.semantic_tokens == %{}
    assert {:scheduled, _, ^current, 0, nil} = receiver.frame_credit

    assert current.intent.frame.highlighting.highlights[buffer] ==
             editor.parser.highlighting.highlights[buffer]
  end

  test "renderer replacement rehydrates while reconnecting the same process preserves the baseline",
       %{editor: editor, render: render} do
    {render, first} = submit(render, editor)
    {same, unchanged} = render |> Render.connect_renderer(self()) |> submit(editor)
    assert same.submitted_highlights == render.submitted_highlights
    assert :erts_debug.flat_size(unchanged) < :erts_debug.flat_size(first)

    replacement = spawn(fn -> :ok end)
    {next, full} = render |> Render.connect_renderer(replacement) |> submit(editor)
    {receiver, restored} = RendererState.receive_submission(RendererState.new([]), full)
    assert next.renderer == replacement
    assert restored == Intent.from_editor_state(editor)
    assert receiver.highlights == editor.parser.highlighting.highlights
  end

  test "frontend reset retains data needed by an unchanged submission", %{
    editor: editor,
    render: render
  } do
    {render, first} = submit(render, editor)
    {receiver, _} = RendererState.receive_submission(RendererState.new([]), first)
    receiver = RendererState.reset_frontend(receiver, 2)
    {_render, unchanged} = submit(render, editor)
    {_receiver, restored} = RendererState.receive_submission(receiver, unchanged)
    assert restored == Intent.from_editor_state(editor)
  end

  test "syntax overrides and frame-local face overrides still travel on unchanged spans", %{
    editor: editor,
    buffer: buffer,
    render: render
  } do
    {render, first} = submit(render, editor)
    {receiver, _} = RendererState.receive_submission(RendererState.new([]), first)
    syntax = %{"keyword" => [fg: 0x123456]}

    updated = %{
      editor
      | parser:
          Parser.accept_highlighting(
            editor.parser,
            Highlighting.set_syntax_overrides(editor.parser.highlighting, %{buffer => syntax})
          )
    }

    intent = Intent.from_editor_state(updated)
    frame = %{intent.frame | face_override_registries: %{buffer => Registry.from_syntax(syntax)}}
    intent = %{intent | frame: frame}

    {_render, delta} =
      Render.prepare_submission(render, intent, updated.lsp.semantic_token_revisions)

    {_receiver, restored} = RendererState.receive_submission(receiver, delta)
    assert restored == intent
  end

  test "a coalesced update survives while the acknowledged frame retains its original highlights",
       %{editor: editor, buffer: buffer, highlight: highlight, render: render} do
    renderer = start_renderer()
    {generation, 0} = Server.acknowledgement_state(renderer)
    {render, first} = submit(render, editor)
    Server.cast_snapshot(renderer, first, 1)
    assert_receive {:presented, 1, ^generation, false, ["keyword"]}, 1_000

    updated = put_highlight(editor, buffer, Highlight.put_names(highlight, ["function"]))
    {render, change} = submit(render, updated)
    {_render, unchanged} = submit(render, updated)
    Server.cast_snapshot(renderer, change, 2)
    Server.cast_snapshot(renderer, unchanged, 3)
    assert Server.rendering?(renderer)

    retained = :sys.get_state(renderer)
    assert {:awaiting_ack, lease, %FrameAttempt{seq: 3}} = retained.frame_credit
    assert lease.attempt.intent.frame.highlighting.highlights[buffer] == highlight
    assert retained.highlights[buffer].capture_names == {"function"}

    Server.frame_status(renderer, {:frame_applied, generation, 1})
    assert_receive {:presented, 3, ^generation, false, ["function"]}, 1_000
    refute_receive {:presented, 2, _, _, _}, 0
    Server.frame_status(renderer, {:frame_applied, generation, 3})
  end

  test "a blocked submission installs its update for the next accepted frame", %{
    editor: editor,
    buffer: buffer,
    highlight: highlight,
    render: render
  } do
    renderer = start_renderer()
    {generation, 0} = Server.acknowledgement_state(renderer)
    {render, first} = submit(render, editor)
    Server.cast_snapshot(renderer, first, 1)
    assert_receive {:presented, 1, ^generation, false, ["keyword"]}, 1_000

    updated = put_highlight(editor, buffer, Highlight.put_names(highlight, ["function"]))
    {render, change} = submit(render, updated)
    Server.cast_snapshot(renderer, change, 2)

    Server.frame_status(
      renderer,
      {:frame_rejected, generation, 1, 0, :unsupported, :terminal_frontend_failure}
    )

    assert Server.terminal_failure(renderer)

    {render, blocked} = submit(render, editor)
    Server.cast_snapshot(renderer, blocked, 3)
    refute Server.rendering?(renderer)
    refute_receive {:presented, 3, _, _, _}, 0

    intent = Intent.from_editor_state(editor, 1)

    {_render, next} =
      Render.prepare_submission(render, intent, editor.lsp.semantic_token_revisions)

    Server.cast_snapshot(renderer, next, 4)
    assert_receive {:presented, 4, ^generation, false, ["keyword"]}, 1_000
    Server.frame_status(renderer, {:frame_applied, generation, 4})
  end

  test "connection reset and recovery hydrate unchanged deltas", %{editor: editor, render: render} do
    renderer = start_renderer()
    {render, first} = submit(render, editor)
    Server.cast_snapshot(renderer, first, 1)
    assert_receive {:presented, 1, generation, false, ["keyword"]}, 1_000
    {render, reset} = submit(render, editor)
    assert :ok = Server.reset_connection(renderer, reset, 2)
    assert_receive {:presented, 2, reset_generation, true, ["keyword"]}, 1_000
    assert reset_generation > generation

    {_render, pending} = submit(render, editor)
    Server.cast_snapshot(renderer, pending, 3)
    assert :recovery_started = Server.request_recovery(renderer, reset_generation, 0)
    assert_receive {:presented, 3, recovered_generation, true, ["keyword"]}, 1_000
    assert recovered_generation > reset_generation
    Server.frame_status(renderer, {:frame_applied, recovered_generation, 3})
  end

  test "headless renders and synchronous reset use the same persistent replica", %{editor: editor} do
    renderer = start_renderer(require_ack?: false)
    editor = %{editor | render: Render.connect_renderer(editor.render, renderer)}
    editor = MingaEditor.Renderer.render_buffer(editor)
    assert_receive {:presented, _, _, false, ["keyword"]}, 1_000
    editor = MingaEditor.Renderer.render_buffer(editor)
    assert_receive {:presented, _, _, false, ["keyword"]}, 1_000
    editor = MingaEditor.Renderer.reset_connection(editor)
    assert_receive {:presented, _, _, true, ["keyword"]}, 1_000
    assert editor.render.submitted_highlights == editor.parser.highlighting.revisions
    assert :sys.get_state(renderer).semantic_tokens == editor.lsp.semantic_tokens
  end

  test "failed adaptation cannot replace highlights reused by a later delta", %{
    editor: editor,
    buffer: buffer,
    highlight: highlight,
    render: render
  } do
    renderer = start_renderer()
    {generation, 0} = Server.acknowledgement_state(renderer)
    {render, first} = submit(render, editor)
    Server.cast_snapshot(renderer, first, 1)
    assert_receive {:presented, 1, ^generation, false, ["keyword"]}, 1_000
    adapted = put_highlight(editor, buffer, Highlight.put_names(highlight, ["wrong"]))

    assert :error =
             Server.record_adaptation(
               renderer,
               generation,
               1,
               :not_a_dimension,
               100,
               10,
               Submission.full(Intent.from_editor_state(adapted))
             )

    {_render, unchanged} = submit(render, editor)
    Server.cast_snapshot(renderer, unchanged, 2)
    Server.frame_status(renderer, {:frame_applied, generation, 1})
    assert_receive {:presented, 2, ^generation, false, ["keyword"]}, 1_000
    Server.frame_status(renderer, {:frame_applied, generation, 2})
  end

  test "the process boundary gate measures compact submissions and focused receipts", %{
    editor: editor,
    buffer: buffer,
    render: render
  } do
    spans = Enum.map(0..39_999, &Span.new(&1 * 4, &1 * 4 + 3, 0))

    editor =
      put_highlight(
        editor,
        buffer,
        Highlight.new() |> Highlight.put_names(["keyword"]) |> Highlight.put_spans(1, spans)
      )

    renderer = start_renderer()
    {generation, 0} = Server.acknowledgement_state(renderer)
    {render, first} = submit(render, editor)
    Server.cast_snapshot(renderer, first, 1)
    assert_receive {:presented, 1, ^generation, false, ["keyword"]}, 1_000
    Server.frame_status(renderer, {:frame_applied, generation, 1})
    assert_receive {:render_done, %RenderReceipt{frame_seq: 1}}, 1_000

    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:minga, :render, :boundary],
        &__MODULE__.collect_boundary/4,
        {self(), renderer}
      )

    on_exit(fn -> :telemetry.detach(id) end)
    {_render, unchanged} = submit(render, editor)
    Server.cast_snapshot(renderer, unchanged, 2)
    assert_receive {:boundary, %{request_bytes: request_bytes}, %{frame_seq: 2}}, 1_000
    assert request_bytes == :erlang.external_size(unchanged)
    assert request_bytes < :erlang.external_size(first)
    assert_receive {:presented, 2, ^generation, false, ["keyword"]}, 1_000
    Server.frame_status(renderer, {:frame_applied, generation, 2})
    assert_receive {:boundary, %{receipt_bytes: receipt_bytes}, %{frame_seq: 2}}, 1_000

    assert ProductionGate.boundary_failures(%{
             request_bytes: request_bytes,
             receipt_bytes: receipt_bytes
           }) == []
  end

  @spec collect_boundary([atom()], map(), map(), {pid(), pid()}) :: :ok
  def collect_boundary(_event, measurements, metadata, {parent, renderer})
      when self() == renderer do
    send(parent, {:boundary, measurements, metadata})
    :ok
  end

  def collect_boundary(_event, _measurements, _metadata, _target), do: :ok

  defp start_renderer(opts \\ []) do
    parent = self()

    pipeline = fn input ->
      names =
        input.intent.frame.highlighting.highlights
        |> Map.values()
        |> Enum.map(&elem(&1.capture_names, 0))

      send(
        parent,
        {:presented, input.frame_seq, input.caches.recovery_generation,
         input.intent.frame.force_keyframe?, names}
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
           generation_reserver: fn -> System.unique_integer([:positive, :monotonic]) end
         ],
         opts
       )}
    )
  end

  defp submit(render, editor),
    do:
      Render.prepare_submission(
        render,
        Intent.from_editor_state(editor),
        editor.lsp.semantic_token_revisions
      )

  defp put_highlight(editor, buffer, highlight) do
    %{
      editor
      | parser:
          Parser.accept_highlighting(
            editor.parser,
            Highlighting.put_highlight(editor.parser.highlighting, buffer, highlight)
          )
    }
  end
end
