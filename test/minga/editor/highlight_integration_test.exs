defmodule Minga.Editor.HighlightIntegrationTest do
  @moduledoc """
  Integration tests for syntax highlighting lifecycle:
  - Buffer switch resets highlight state (prevents stale spans)
  - Highlight setup triggers after :ready (correct viewport)
  - Invalid byte boundaries in spans produce safe output
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Editor.HighlightBridge
  alias Minga.Highlight

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

      Process.sleep(50)

      state = :sys.get_state(ctx.editor)
      assert state.highlight.spans != [], "Pre-condition: file1 should have spans"

      # Open second file via :e — triggers buffer switch
      send_keys(ctx, ":e #{path2}<CR>")
      Process.sleep(50)

      state = :sys.get_state(ctx.editor)

      assert state.highlight.spans == [],
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
      Process.sleep(50)

      # Inject spans for file2
      send(ctx.editor, {:minga_input, {:highlight_names, ["keyword"]}})

      send(
        ctx.editor,
        {:minga_input, {:highlight_spans, 1, [%{start_byte: 0, end_byte: 9, capture_id: 0}]}}
      )

      Process.sleep(50)
      state = :sys.get_state(ctx.editor)
      assert state.highlight.spans != [], "Pre-condition: file2 should have spans"

      # Switch to previous buffer via SPC b n
      send_keys(ctx, "<Space>bn")
      Process.sleep(50)

      state = :sys.get_state(ctx.editor)

      assert state.highlight.spans == [],
             "Stale spans from file2 persisted after SPC b n"
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

  describe "highlight setup timing" do
    test "new editor has empty highlights before :ready" do
      id = :erlang.unique_integer([:positive])
      {:ok, port} = Minga.Test.HeadlessPort.start_link(width: 80, height: 24)
      {:ok, buffer} = BufferServer.start_link(content: "defmodule Foo do\nend\n")

      {:ok, editor} =
        Minga.Editor.start_link(
          name: :"hl_timing_#{id}",
          port_manager: port,
          buffer: buffer,
          width: 80,
          height: 24
        )

      state = :sys.get_state(editor)
      assert state.highlight.spans == []
      assert state.highlight.capture_names == []
    end
  end

  describe "highlight state management" do
    test "handle_names then handle_spans builds complete state" do
      state =
        base_state()
        |> HighlightBridge.handle_names(["keyword", "string", "comment"])
        |> HighlightBridge.handle_spans(1, [
          %{start_byte: 0, end_byte: 9, capture_id: 0},
          %{start_byte: 10, end_byte: 15, capture_id: 1}
        ])

      assert state.highlight.capture_names == ["keyword", "string", "comment"]
      assert length(state.highlight.spans) == 2
      assert state.highlight.version == 1
    end

    test "receiving new names clears old names without affecting spans" do
      state =
        base_state()
        |> HighlightBridge.handle_names(["keyword"])
        |> HighlightBridge.handle_spans(1, [%{start_byte: 0, end_byte: 5, capture_id: 0}])
        |> HighlightBridge.handle_names(["new_keyword", "new_string"])

      assert state.highlight.capture_names == ["new_keyword", "new_string"]
      assert length(state.highlight.spans) == 1
    end
  end

  # ── Helpers ──

  defp base_state do
    %Minga.Editor.State{
      port_manager: nil,
      viewport: Minga.Editor.Viewport.new(24, 80),
      mode: :normal,
      mode_state: Minga.Mode.initial_state()
    }
  end
end
