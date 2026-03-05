defmodule Minga.Editor.HighlightIntegrationTest do
  @moduledoc """
  Integration tests for syntax highlighting lifecycle:
  - Buffer switch resets highlight state (prevents stale spans)
  - Highlight setup triggers after :ready (correct viewport)
  - Invalid byte boundaries in spans produce safe output
  """

  use Minga.Test.EditorCase, async: false

  alias Minga.Editor
  alias Minga.Editor.HighlightSync
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Highlight
  alias Minga.Mode
  alias Minga.Test.HeadlessPort

  describe "buffer switch resets highlights" do
    @tag :tmp_dir
    test "opening a new file via :e clears stale highlights", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "file1.ex")
      path2 = Path.join(tmp_dir, "file2.ex")
      File.write!(path1, "defmodule A do\nend\n")
      File.write!(path2, "defmodule B do\nend\n")

      ctx = start_editor("defmodule A do\nend\n", file_path: path1)

      # Inject highlight data as if Zig responded for file1
      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})

      send(
        ctx.editor,
        {:minga_input, {:highlight_spans, 1, [%{start_byte: 0, end_byte: 9, capture_id: 0}]}}
      )

      state = :sys.get_state(ctx.editor)
      assert state.highlight.current.spans != [], "Pre-condition: file1 should have spans"

      # Open second file via :e — triggers buffer switch
      send_keys(ctx, ":e #{path2}<CR>")

      state = :sys.get_state(ctx.editor)

      assert state.highlight.current.spans == [],
             "Stale spans from file1 persisted after :e to file2"
    end

    @tag :tmp_dir
    test "SPC b n clears stale highlights", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "a.ex")
      path2 = Path.join(tmp_dir, "b.ex")
      File.write!(path1, "defmodule A do\nend\n")
      File.write!(path2, "defmodule B do\nend\n")

      ctx = start_editor("defmodule A do\nend\n", file_path: path1)

      # Open second file
      send_keys(ctx, ":e #{path2}<CR>")

      # Inject spans for file2
      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})

      send(
        ctx.editor,
        {:minga_input, {:highlight_spans, 1, [%{start_byte: 0, end_byte: 9, capture_id: 0}]}}
      )

      state = :sys.get_state(ctx.editor)
      assert state.highlight.current.spans != [], "Pre-condition: file2 should have spans"

      # Switch to previous buffer via SPC b n
      send_keys(ctx, "<Space>bn")

      state = :sys.get_state(ctx.editor)

      assert state.highlight.current.spans == [],
             "Stale spans from file2 persisted after SPC b n"
    end
  end

  describe "picker (SPC f f) resets highlights" do
    @tag :tmp_dir
    test "selecting a file via picker clears stale highlights", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "aaa.ex")
      path2 = Path.join(tmp_dir, "bbb.ex")
      File.write!(path1, "defmodule A do\nend\n")
      File.write!(path2, "defmodule B do\nend\n")

      # cd into tmp_dir so the file picker can find the test files
      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      ctx = start_editor("defmodule A do\nend\n", file_path: path1)

      # Inject highlights for file1
      spans_a = [%{start_byte: 0, end_byte: 9, capture_id: 0}]
      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})
      send(ctx.editor, {:minga_input, {:highlight_spans, 1, spans_a}})

      state = :sys.get_state(ctx.editor)
      assert state.highlight.current.spans == spans_a

      # Open file2 via SPC f f picker
      send_keys(ctx, "<Space>ff")

      # Type enough to match bbb.ex, then Enter
      type_text(ctx, "bbb")
      send_key(ctx, 13)

      state = :sys.get_state(ctx.editor)
      File.cd!(original_dir)

      assert state.highlight.current.spans == [],
             "Stale spans from file1 persisted after SPC f f to file2"
    end

    @tag :tmp_dir
    test "picker caches highlights for previous buffer", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "aaa.ex")
      path2 = Path.join(tmp_dir, "bbb.ex")
      File.write!(path1, "defmodule A do\nend\n")
      File.write!(path2, "defmodule B do\nend\n")

      # cd into tmp_dir so the file picker can find the test files
      original_dir = File.cwd!()
      File.cd!(tmp_dir)

      ctx = start_editor("defmodule A do\nend\n", file_path: path1)

      # Inject highlights for file1
      spans_a = [%{start_byte: 0, end_byte: 9, capture_id: 0}]
      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})
      send(ctx.editor, {:minga_input, {:highlight_spans, 1, spans_a}})

      buf1_pid = :sys.get_state(ctx.editor).buffers.active

      # Switch to file2 via picker
      send_keys(ctx, "<Space>ff")
      type_text(ctx, "bbb")
      send_key(ctx, 13)

      state = :sys.get_state(ctx.editor)
      File.cd!(original_dir)

      # Verify cache was populated for file1
      assert Map.has_key?(state.highlight.cache, buf1_pid),
             "Expected file1 highlights to be cached after picker switch"

      cached = state.highlight.cache[buf1_pid]
      assert cached.spans == spans_a
    end
  end

  describe "stale spans produce valid output" do
    test "styles_for_line with mismatched spans on Unicode line" do
      # Simulates: spans from auto_pair.ex applied to editor.ex content
      # containing Unicode box-drawing characters (─ is 3 bytes each)
      hl = %Highlight{
        version: 1,
        spans: [
          %{start_byte: 2, end_byte: 5, capture_id: 0},
          %{start_byte: 10, end_byte: 20, capture_id: 0}
        ],
        capture_names: ["keyword"],
        theme: %{"keyword" => [fg: 0xFF0000]}
      }

      line = "# ── Server Callbacks ──────"
      segments = Highlight.styles_for_line(hl, line, 0)

      all_text = Enum.map_join(segments, fn {text, _style} -> text end)
      assert String.valid?(all_text), "Segments produced invalid UTF-8: #{inspect(all_text)}"
      assert all_text == line
    end

    test "styles_for_line with span boundary inside multi-byte character" do
      # ─ (U+2500) is 3 bytes: E2 94 80
      # Span at byte 1 lands inside the first character
      line = "──"

      hl = %Highlight{
        version: 1,
        spans: [%{start_byte: 0, end_byte: 1, capture_id: 0}],
        capture_names: ["comment"],
        theme: %{"comment" => [fg: 0x888888]}
      }

      # Must not crash; byte count must be preserved
      segments = Highlight.styles_for_line(hl, line, 0)
      all_text = Enum.map_join(segments, fn {text, _style} -> text end)
      assert byte_size(all_text) == byte_size(line)
    end

    test "styles_for_line with span at valid character boundary" do
      # ─ is 3 bytes; span covers exactly the first character (bytes 0-3)
      line = "──"

      hl = %Highlight{
        version: 1,
        spans: [%{start_byte: 0, end_byte: 3, capture_id: 0}],
        capture_names: ["comment"],
        theme: %{"comment" => [fg: 0x888888]}
      }

      segments = Highlight.styles_for_line(hl, line, 0)
      all_text = Enum.map_join(segments, fn {text, _style} -> text end)
      assert String.valid?(all_text)
      assert all_text == line
      assert [{"─", [fg: 0x888888]}, {"─", []}] = segments
    end
  end

  describe ":e restores cached highlights" do
    @tag :tmp_dir
    test ":e back to previously highlighted file uses cache", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "file1.ex")
      path2 = Path.join(tmp_dir, "file2.ex")
      File.write!(path1, "defmodule A do\nend\n")
      File.write!(path2, "defmodule B do\nend\n")

      ctx = start_editor("defmodule A do\nend\n", file_path: path1)

      # Inject highlights for file1
      spans_a = [%{start_byte: 0, end_byte: 9, capture_id: 0}]
      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})
      send(ctx.editor, {:minga_input, {:highlight_spans, 1, spans_a}})

      # Switch to file2
      send_keys(ctx, ":e #{path2}<CR>")

      assert :sys.get_state(ctx.editor).highlight.current.spans == []

      # Switch back to file1 via :e (should already be in buffer list)
      send_keys(ctx, ":e #{path1}<CR>")

      state = :sys.get_state(ctx.editor)

      assert state.highlight.current.spans == spans_a,
             "Expected cached spans restored via :e, got: #{inspect(state.highlight.current.spans)}"
    end
  end

  describe "highlight cache across buffer switches" do
    @tag :tmp_dir
    test "switching back to a previously highlighted buffer restores cached spans",
         %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "a.ex")
      path2 = Path.join(tmp_dir, "b.ex")
      File.write!(path1, "defmodule A do\nend\n")
      File.write!(path2, "defmodule B do\nend\n")

      ctx = start_editor("defmodule A do\nend\n", file_path: path1)

      # Inject highlights for file1
      spans_a = [%{start_byte: 0, end_byte: 9, capture_id: 0}]
      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})
      send(ctx.editor, {:minga_input, {:highlight_spans, 1, spans_a}})

      state = :sys.get_state(ctx.editor)
      assert state.highlight.current.spans == spans_a

      # Open file2 and switch to it
      send_keys(ctx, ":e #{path2}<CR>")

      state = :sys.get_state(ctx.editor)
      assert state.highlight.current.spans == [], "File2 should start with empty spans"

      # Switch back to file1 — should restore cached highlights instantly
      send_keys(ctx, "<Space>bn")

      state = :sys.get_state(ctx.editor)

      assert state.highlight.current.spans == spans_a,
             "Expected cached spans from file1 to be restored, got: #{inspect(state.highlight.current.spans)}"
    end
  end

  describe "highlight setup timing" do
    test "new editor has empty highlights before :ready" do
      id = :erlang.unique_integer([:positive])
      {:ok, port} = HeadlessPort.start_link(width: 80, height: 24)
      {:ok, buffer} = BufferServer.start_link(content: "defmodule Foo do\nend\n")

      {:ok, editor} =
        Editor.start_link(
          name: :"hl_timing_#{id}",
          port_manager: port,
          buffer: buffer,
          width: 80,
          height: 24
        )

      state = :sys.get_state(editor)
      assert state.highlight.current.spans == []
      assert state.highlight.current.capture_names == []
    end
  end

  describe "highlight state management" do
    test "handle_names then handle_spans builds complete state" do
      state =
        base_state()
        |> HighlightSync.handle_names(["keyword", "string", "comment"])
        |> HighlightSync.handle_spans(1, [
          %{start_byte: 0, end_byte: 9, capture_id: 0},
          %{start_byte: 10, end_byte: 15, capture_id: 1}
        ])

      assert state.highlight.current.capture_names == ["keyword", "string", "comment"]
      assert length(state.highlight.current.spans) == 2
      assert state.highlight.current.version == 1
    end

    test "receiving new names clears old names without affecting spans" do
      state =
        base_state()
        |> HighlightSync.handle_names(["keyword"])
        |> HighlightSync.handle_spans(1, [%{start_byte: 0, end_byte: 5, capture_id: 0}])
        |> HighlightSync.handle_names(["new_keyword", "new_string"])

      assert state.highlight.current.capture_names == ["new_keyword", "new_string"]
      assert length(state.highlight.current.spans) == 1
    end
  end

  describe "normal-mode operator reparse" do
    test "dd triggers highlight reparse" do
      ctx = start_editor("line one\nline two\nline three")

      # Inject highlights so reparse path is active
      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})

      send(
        ctx.editor,
        {:minga_input, {:highlight_spans, 1, [%{start_byte: 0, end_byte: 4, capture_id: 0}]}}
      )

      version_before = :sys.get_state(ctx.editor).highlight.version

      # dd deletes the current line
      send_keys(ctx, "dd")

      version_after = :sys.get_state(ctx.editor).highlight.version

      assert version_after > version_before,
             "Expected highlight_version to increment after dd (#{version_before} → #{version_after})"
    end

    test "x triggers highlight reparse" do
      ctx = start_editor("hello")

      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})

      send(
        ctx.editor,
        {:minga_input, {:highlight_spans, 1, [%{start_byte: 0, end_byte: 5, capture_id: 0}]}}
      )

      version_before = :sys.get_state(ctx.editor).highlight.version

      # Trace setup_highlight calls
      :erlang.trace(ctx.editor, true, [:receive])

      send_key(ctx, ?x)

      # Collect any setup_highlight messages
      receive do
        {:trace, _, :receive, :setup_highlight} ->
          IO.puts("GOT setup_highlight AFTER x")
      after
        50 -> IO.puts("No setup_highlight after x")
      end

      :erlang.trace(ctx.editor, false, [:receive])

      version_after = :sys.get_state(ctx.editor).highlight.version

      assert version_after > version_before,
             "Expected highlight_version to increment after x"
    end

    test "p (paste) triggers highlight reparse" do
      ctx = start_editor("hello world")

      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})

      send(
        ctx.editor,
        {:minga_input, {:highlight_spans, 1, [%{start_byte: 0, end_byte: 5, capture_id: 0}]}}
      )

      # Yank a word first (yw), then paste
      send_keys(ctx, "yw")

      version_before = :sys.get_state(ctx.editor).highlight.version

      send_key(ctx, ?p)

      version_after = :sys.get_state(ctx.editor).highlight.version

      assert version_after > version_before,
             "Expected highlight_version to increment after p"
    end

    test "undo triggers highlight reparse" do
      ctx = start_editor("hello world")

      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})

      send(
        ctx.editor,
        {:minga_input, {:highlight_spans, 1, [%{start_byte: 0, end_byte: 5, capture_id: 0}]}}
      )

      # Make a change first
      send_key(ctx, ?x)

      version_before = :sys.get_state(ctx.editor).highlight.version

      # Undo
      send_key(ctx, ?u)

      version_after = :sys.get_state(ctx.editor).highlight.version

      assert version_after > version_before,
             "Expected highlight_version to increment after undo"
    end

    test "motion-only keys do not trigger reparse" do
      ctx = start_editor("hello world\nsecond line")

      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})

      send(
        ctx.editor,
        {:minga_input, {:highlight_spans, 1, [%{start_byte: 0, end_byte: 5, capture_id: 0}]}}
      )

      version_before = :sys.get_state(ctx.editor).highlight.version

      # Pure motions: h, j, k, l, w
      send_keys(ctx, "llljkw")

      version_after = :sys.get_state(ctx.editor).highlight.version

      assert version_after == version_before,
             "Expected highlight_version unchanged after motions (#{version_before} → #{version_after})"
    end
  end

  describe "edge cases" do
    @tag :tmp_dir
    test "unsupported filetype renders without crash", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.xyz")
      File.write!(path, "just plain text")
      ctx = start_editor("just plain text", file_path: path)

      # Should render normally with no highlights
      assert_row_contains(ctx, 0, "just plain text")

      state = :sys.get_state(ctx.editor)
      assert state.highlight.current.capture_names == []
      assert state.highlight.current.spans == []
    end

    test "empty file renders without crash" do
      ctx = start_editor("")

      # Should show empty first line and tildes
      state = :sys.get_state(ctx.editor)
      assert state.highlight.current.spans == []
    end

    test "file with syntax errors still renders partial highlights" do
      # Incomplete Elixir — defmodule without end
      _content = "defmodule Broken do\n  def foo, do: :\nno end here"

      hl = %Highlight{
        version: 1,
        spans: [
          %{start_byte: 0, end_byte: 9, capture_id: 0},
          %{start_byte: 22, end_byte: 25, capture_id: 1}
        ],
        capture_names: ["keyword", "function"],
        theme: %{"keyword" => [fg: 0xFF0000], "function" => [fg: 0x00FF00]}
      }

      # First line: "defmodule Broken do" — span 0-9 covers "defmodule"
      segments = Highlight.styles_for_line(hl, "defmodule Broken do", 0)
      all_text = Enum.map_join(segments, fn {text, _} -> text end)
      assert all_text == "defmodule Broken do"

      # "defmodule" should have keyword style
      {first_text, first_style} = hd(segments)
      assert first_text == "defmodule"
      assert first_style[:fg] == 0xFF0000
    end

    test "styles_for_line with empty line returns single empty segment" do
      hl = %Highlight{
        version: 1,
        spans: [%{start_byte: 0, end_byte: 10, capture_id: 0}],
        capture_names: ["keyword"],
        theme: %{"keyword" => [fg: 0xFF0000]}
      }

      segments = Highlight.styles_for_line(hl, "", 5)
      assert segments == []
    end
  end

  describe "insert mode reparse" do
    test "typing in insert mode triggers reparse" do
      ctx = start_editor("hello")

      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})

      send(
        ctx.editor,
        {:minga_input, {:highlight_spans, 1, [%{start_byte: 0, end_byte: 5, capture_id: 0}]}}
      )

      version_before = :sys.get_state(ctx.editor).highlight.version

      send_key(ctx, ?i)
      send_key(ctx, ?a)

      version_after = :sys.get_state(ctx.editor).highlight.version

      assert version_after > version_before,
             "Expected highlight_version to increment after insert mode typing"
    end
  end

  # ── Helpers ──

  defp base_state do
    %EditorState{
      port_manager: nil,
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Mode.initial_state()
    }
  end
end
