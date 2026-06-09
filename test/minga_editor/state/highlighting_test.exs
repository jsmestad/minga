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
end
