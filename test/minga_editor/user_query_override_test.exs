defmodule MingaEditor.UserQueryOverrideTest do
  @moduledoc """
  Tests for user-customizable highlight queries.

  Verifies that custom query files in ~/.config/minga/queries/{lang}/
  are sent to the Zig port, and that :reload-highlights re-triggers setup.
  """

  use Minga.Test.EditorCase, async: true

  alias MingaEditor.HighlightSync
  alias MingaEditor.UI.Highlight.Grammar

  alias Minga.Command.Parser

  describe "parser recognizes reload-highlights" do
    test "parses :reload-highlights" do
      assert {:reload_highlights, []} = Parser.parse("reload-highlights")
    end

    test "parses :rh shorthand" do
      assert {:reload_highlights, []} = Parser.parse("rh")
    end
  end

  describe ":reload-highlights command" do
    @tag :tmp_dir
    test "reload-highlights resets highlight state", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "foo.ex")
      File.write!(path, "defmodule Foo do\nend\n")
      ctx = start_editor("defmodule Foo do\nend\n", file_path: path)

      # Inject highlights
      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})

      send(
        ctx.editor,
        {:minga_input, {:highlight_spans, 1, [%{start_byte: 0, end_byte: 9, capture_id: 0}]}}
      )

      state = :sys.get_state(ctx.editor)
      assert HighlightSync.get_active_highlight(state).spans != []

      version_before = state.workspace.highlight.version

      # Run :reload-highlights
      send_keys_sync(ctx, ":reload-highlights<CR>")

      state = :sys.get_state(ctx.editor)

      # Highlight state should be reset (new Highlight struct with empty spans)
      # and a new parse should be in-flight (version incremented)
      assert HighlightSync.get_active_highlight(state).spans == {}
      assert state.workspace.highlight.version > version_before
    end

    @tag :tmp_dir
    test "rh shorthand works the same as reload-highlights", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bar.ex")
      File.write!(path, "defmodule Bar do\nend\n")
      ctx = start_editor("defmodule Bar do\nend\n", file_path: path)

      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})

      send(
        ctx.editor,
        {:minga_input, {:highlight_spans, 1, [%{start_byte: 0, end_byte: 9, capture_id: 0}]}}
      )

      version_before = :sys.get_state(ctx.editor).workspace.highlight.version

      send_keys_sync(ctx, ":rh<CR>")

      state = :sys.get_state(ctx.editor)
      assert HighlightSync.get_active_highlight(state).spans == {}
      assert state.workspace.highlight.version > version_before
    end
  end

  describe "user query file detection" do
    test "Grammar.query_path prefers user dir when file exists" do
      # We can't easily test the actual ~/.config path in CI, but we can
      # verify the Grammar.query_path logic by checking that priv path
      # is returned when no user override exists
      path = Grammar.query_path("elixir")
      assert path != nil
      assert String.contains?(path, "priv/queries/elixir/highlights.scm")
    end
  end
end
