defmodule MingaEditor.State.HighlightingTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Highlighting
  alias MingaEditor.UI.Face.Registry
  alias MingaEditor.UI.Highlight
  alias MingaEditor.UI.Theme

  describe "retheme_all/2" do
    test "rebuilds normal buffers from the new theme but leaves override buffers untouched" do
      normal_pid = self()
      override_pid = spawn(fn -> :ok end)

      override_syntax = %{"keyword" => [fg: 0x123456]}

      state =
        %Highlighting{}
        |> Highlighting.put_highlight(normal_pid, Highlight.from_theme(Theme.get!(:doom_one)))
        |> Highlighting.put_highlight(override_pid, Highlight.new(override_syntax))
        |> Highlighting.set_syntax_overrides(%{override_pid => override_syntax})

      one_light = Theme.get!(:one_light)
      rethemed = Highlighting.retheme_all(state, one_light)

      # Normal buffer picks up the new theme's palette.
      normal_hl = rethemed.highlights[normal_pid]
      assert normal_hl.theme == one_light.syntax

      # Override buffer keeps its custom, theme-independent palette.
      override_hl = rethemed.highlights[override_pid]
      assert override_hl.theme == override_syntax

      assert Registry.style_for(override_hl.face_registry, "keyword").fg == 0x123456
    end
  end

  test "source revisions preserve no-op and stale updates, and follow removals" do
    buffer = self()
    highlight = Highlight.new() |> Highlight.put_names(["keyword"]) |> Highlight.put_spans(2, [])
    source = Highlighting.put_highlight(%Highlighting{}, buffer, highlight)
    assert Highlighting.put_highlight(source, buffer, highlight).revisions == source.revisions

    assert Highlighting.put_highlight(source, buffer, Highlight.put_spans(highlight, 1, [])).revisions ==
             source.revisions

    replacement =
      Highlighting.put_highlight(source, buffer, Highlight.put_spans(highlight, 2, []))

    refute replacement.revisions == source.revisions
    assert Highlighting.set_highlights(source, source.highlights).revisions == source.revisions
    assert Highlighting.set_highlights(source, %{}).revisions == %{}
    assert Highlighting.remove_buffer(source, buffer).revisions == %{}
  end

  test "retheme preserves custom overrides and changes only affected source revisions" do
    buffer = self()
    overridden = spawn(fn -> :ok end)

    source =
      %Highlighting{}
      |> Highlighting.put_highlight(buffer, Highlight.from_theme(Theme.get!(:doom_one)))
      |> Highlighting.put_highlight(overridden, Highlight.new(%{"keyword" => [fg: 0x123456]}))
      |> Highlighting.set_syntax_overrides(%{overridden => %{}})

    changed = Highlighting.retheme_all(source, Theme.get!(:one_light))
    refute changed.revisions[buffer] == source.revisions[buffer]
    assert changed.revisions[overridden] == source.revisions[overridden]
    assert Map.keys(changed.revisions) == Map.keys(changed.highlights)
  end

  test "semantic revisions follow accepted responses, clears, and buffer retirement" do
    alias MingaEditor.State.LSP
    buffer = self()
    source = LSP.accept_semantic_tokens(%LSP{}, buffer, 1, ["@lsp.type.variable"], [])
    replaced = LSP.accept_semantic_tokens(source, buffer, 1, ["@lsp.type.variable"], [])
    refute source.semantic_token_revisions[buffer] == replaced.semantic_token_revisions[buffer]
    assert Map.keys(replaced.semantic_token_revisions) == Map.keys(replaced.semantic_tokens)
    assert LSP.clear_semantic_tokens(replaced, buffer).semantic_token_revisions == %{}
    assert LSP.retire_buffer(replaced, buffer).semantic_token_revisions == %{}
  end
end
