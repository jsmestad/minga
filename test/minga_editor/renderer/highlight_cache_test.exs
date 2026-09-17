defmodule MingaEditor.Renderer.HighlightCacheTest do
  use ExUnit.Case, async: true

  alias Minga.Language.Highlight.Span
  alias MingaEditor.RenderPipeline.{ContentHelpers, Input, Intent, TestHelpers}
  alias MingaEditor.Renderer.{BufferChanges, HighlightCache, State, Submission}
  alias MingaEditor.State.{Highlighting, LSP, Parser}
  alias MingaEditor.UI.{Highlight, Theme}

  setup do
    editor = TestHelpers.base_state(filetype: :text)
    buffer = editor.workspace.buffers.active

    syntax =
      Highlight.new()
      |> Highlight.put_names(["keyword"])
      |> Highlight.put_spans(1, [Span.new(0, 3, 0)])

    editor = put_syntax(editor, buffer, syntax)

    editor = %{
      editor
      | lsp:
          LSP.accept_semantic_tokens(editor.lsp, buffer, 1, ["@lsp.type.variable"], [
            Span.new(4, 7, 0)
          ])
    }

    %{editor: editor, buffer: buffer, syntax: syntax, intent: Intent.from_editor_state(editor)}
  end

  test "unchanged preparation work stays bounded as span count grows", %{
    editor: editor,
    buffer: buffer
  } do
    costs =
      for count <- [10, 40_000] do
        spans = for i <- 0..(count - 1), do: Span.new(i * 4, i * 4 + 3, 0)

        syntax =
          Highlight.new() |> Highlight.put_names(["keyword"]) |> Highlight.put_spans(1, spans)

        editor = put_syntax(editor, buffer, syntax)

        editor = %{
          editor
          | lsp: LSP.accept_semantic_tokens(editor.lsp, buffer, 1, ["@lsp.type.variable"], spans)
        }

        intent = Intent.from_editor_state(editor)
        {cache, prepared} = HighlightCache.prepare(HighlightCache.new(), intent)
        assert tuple_size(prepared[buffer].spans) == count * 2
        :erlang.garbage_collect()
        {:reductions, before_count} = Process.info(self(), :reductions)
        Enum.each(1..100, fn _ -> HighlightCache.prepare(cache, intent) end)
        {:reductions, after_count} = Process.info(self(), :reductions)
        after_count - before_count
      end

    [small, large] = costs
    assert large <= small * 2
  end

  test "two windows share one composition and hidden buffers retain it", %{
    intent: intent,
    buffer: buffer
  } do
    window = intent.windows[intent.window_layout.active]
    intent = %{intent | windows: %{1 => window, 2 => window}}
    {cache, prepared} = HighlightCache.prepare(HighlightCache.new(), intent)
    assert map_size(prepared) == 1
    {hidden_cache, %{}} = HighlightCache.prepare(cache, %{intent | windows: %{}})
    assert hidden_cache == cache
    {same_cache, shown} = HighlightCache.prepare(hidden_cache, intent)
    assert same_cache == cache
    assert :erts_debug.same(shown[buffer], prepared[buffer])
  end

  test "syntax changes and same-version semantic replacements invalidate composition", %{
    editor: editor,
    intent: intent,
    buffer: buffer,
    syntax: syntax
  } do
    {cache, original} = HighlightCache.prepare(HighlightCache.new(), intent)
    changed = put_syntax(editor, buffer, Highlight.put_spans(syntax, 1, [Span.new(8, 10, 0)]))
    {cache, prepared} = HighlightCache.prepare(cache, Intent.from_editor_state(changed))
    refute prepared[buffer].spans == original[buffer].spans

    changed = %{
      changed
      | lsp:
          LSP.accept_semantic_tokens(changed.lsp, buffer, 1, ["@lsp.type.function"], [
            Span.new(11, 14, 0)
          ])
    }

    {_cache, replaced} = HighlightCache.prepare(cache, Intent.from_editor_state(changed))
    assert replaced[buffer].capture_names == {"keyword", "@lsp.type.function"}
    assert Enum.map(Tuple.to_list(replaced[buffer].spans), & &1.start_byte) == [8, 11]
  end

  test "source clearing leaves only the remaining layer, then no highlights", %{
    editor: editor,
    intent: intent,
    buffer: buffer,
    syntax: syntax
  } do
    {cache, _} = HighlightCache.prepare(HighlightCache.new(), intent)
    no_semantic = %{editor | lsp: LSP.clear_semantic_tokens(editor.lsp, buffer)}
    {_cache, syntax_only} = HighlightCache.prepare(cache, Intent.from_editor_state(no_semantic))
    assert syntax_only[buffer] == syntax
    no_syntax = %{editor | parser: Parser.retire_buffer(editor.parser, buffer)}
    {cache, semantic_only} = HighlightCache.prepare(cache, Intent.from_editor_state(no_syntax))
    assert semantic_only[buffer].capture_names == {"@lsp.type.variable"}
    empty = %{no_syntax | lsp: LSP.clear_semantic_tokens(editor.lsp, buffer)}
    {cache, prepared} = HighlightCache.prepare(cache, Intent.from_editor_state(empty))
    assert prepared[buffer] == nil

    {cache, %{}} =
      HighlightCache.prepare(cache, %{Intent.from_editor_state(empty) | windows: %{}})

    assert cache == HighlightCache.new()
  end

  test "semantic-only fallback theme and installed syntax theme changes take effect", %{
    editor: editor,
    intent: intent,
    buffer: buffer
  } do
    {cache, original} = HighlightCache.prepare(HighlightCache.new(), intent)
    theme = Theme.get!(:one_light)

    changed = %{
      editor
      | parser:
          Parser.accept_highlighting(
            editor.parser,
            Highlighting.retheme_all(editor.parser.highlighting, theme)
          )
    }

    {_cache, themed} = HighlightCache.prepare(cache, Intent.from_editor_state(changed))
    refute themed[buffer].face_registry == original[buffer].face_registry
    semantic_only = %{editor | parser: Parser.retire_buffer(editor.parser, buffer)}
    intent = Intent.from_editor_state(semantic_only)
    {cache, original} = HighlightCache.prepare(cache, intent)

    {_cache, themed} =
      HighlightCache.prepare(cache, %{intent | frame: %{intent.frame | theme: theme}})

    refute themed[buffer].face_registry == original[buffer].face_registry
  end

  test "face overrides change without rebuilding composed spans", %{
    intent: intent,
    buffer: buffer
  } do
    {renderer, input} = BufferChanges.prepare(State.new([]), intent)
    registry = Highlight.new(%{"@lsp.type.variable" => [fg: 0x123456]}).face_registry
    changed = %{intent | frame: %{intent.frame | face_override_registries: %{buffer => registry}}}
    {_renderer, next} = BufferChanges.prepare(renderer, changed)
    assert :erts_debug.same(input.composed_highlights[buffer], next.composed_highlights[buffer])
    highlight = ContentHelpers.window_highlight(next, next.windows.map[next.windows.active])
    assert highlight.face_registry == registry
    assert next.intent == changed
  end

  test "frontend reset retains composition and buffer lifecycle removes it", %{
    intent: intent,
    buffer: buffer
  } do
    {state, restored} = State.receive_submission(State.new([]), Submission.full(intent))
    assert state.highlight_cache == HighlightCache.new()
    {state, input} = BufferChanges.prepare(state, restored)
    reset = State.reset_frontend(state, 1)
    assert reset.highlight_cache == state.highlight_cache
    {_reset, next} = BufferChanges.prepare(reset, restored)
    assert :erts_debug.same(input.composed_highlights[buffer], next.composed_highlights[buffer])
    {down, true} = State.drop_buffer_down(state, state.observed_buffers.monitors[buffer], buffer)
    assert down.highlight_cache == HighlightCache.new()
    assert down.highlights == state.highlights
    empty = Intent.with_highlight_payload(intent, %{}, %{})
    {removed, _} = State.receive_submission(state, Submission.full(empty))
    assert removed.highlight_cache == HighlightCache.new()
  end

  test "unchanged submissions preserve plain-text cache and changed sources discard hidden compositions",
       %{editor: editor, buffer: buffer, intent: intent} do
    empty = %{
      editor
      | parser: Parser.retire_buffer(editor.parser, buffer),
        lsp: LSP.clear_semantic_tokens(editor.lsp, buffer)
    }

    plain = Intent.from_editor_state(empty)
    {state, _} = BufferChanges.prepare(State.new([]), plain)
    {next, _} = State.receive_submission(state, Submission.full(plain))
    assert next.highlight_cache == state.highlight_cache

    {state, _} = BufferChanges.prepare(state, intent)
    changed = %{editor | lsp: LSP.clear_semantic_tokens(editor.lsp, buffer)}
    hidden = %{Intent.from_editor_state(changed) | windows: %{}}
    {next, _} = State.receive_submission(state, Submission.full(hidden))
    assert next.highlight_cache == HighlightCache.new()
  end

  test "older immutable attempts use their own sources after a newer submission", %{
    editor: editor,
    intent: intent,
    buffer: buffer
  } do
    {state, first} = State.receive_submission(State.new([]), Submission.full(intent))
    {state, old} = BufferChanges.prepare(state, first)

    editor = %{
      editor
      | lsp:
          LSP.accept_semantic_tokens(editor.lsp, buffer, 1, ["@lsp.type.function"], [
            Span.new(8, 11, 0)
          ])
    }

    latest = Intent.from_editor_state(editor)
    {state, latest} = State.receive_submission(state, Submission.full(latest))
    {state, current} = BufferChanges.prepare(state, latest)
    refute current.composed_highlights[buffer].spans == old.composed_highlights[buffer].spans
    {state, retried} = BufferChanges.prepare(state, first)
    assert retried.composed_highlights[buffer] == old.composed_highlights[buffer]
    assert state.semantic_tokens == latest.frame.semantic_tokens
  end

  test "headless construction uses the same prepared highlight contract", %{
    editor: editor,
    intent: intent
  } do
    {_state, input} = BufferChanges.prepare(State.new([]), intent)
    assert Input.from_editor_state(editor).composed_highlights == input.composed_highlights
  end

  defp put_syntax(editor, buffer, syntax) do
    highlighting = Highlighting.put_highlight(editor.parser.highlighting, buffer, syntax)
    %{editor | parser: Parser.accept_highlighting(editor.parser, highlighting)}
  end
end
