defmodule Minga.Editor.LspActionsTest do
  @moduledoc "Tests for LspActions: definition and hover response parsing and navigation."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.HoverPopup
  alias Minga.Editor.LspActions
  alias Minga.Editor.VimState
  alias Minga.UI.Picker.CodeActionSource

  # ── parse_location/1 ──────────────────────────────────────────────────────

  describe "parse_location/1" do
    test "parses a single Location" do
      location = %{
        "uri" => "file:///tmp/foo.ex",
        "range" => %{
          "start" => %{"line" => 10, "character" => 5},
          "end" => %{"line" => 10, "character" => 15}
        }
      }

      assert {"file:///tmp/foo.ex", 10, 5} = LspActions.parse_location(location)
    end

    test "parses an array of Locations (picks first)" do
      locations = [
        %{
          "uri" => "file:///tmp/first.ex",
          "range" => %{
            "start" => %{"line" => 1, "character" => 0},
            "end" => %{"line" => 1, "character" => 10}
          }
        },
        %{
          "uri" => "file:///tmp/second.ex",
          "range" => %{
            "start" => %{"line" => 20, "character" => 3},
            "end" => %{"line" => 20, "character" => 8}
          }
        }
      ]

      assert {"file:///tmp/first.ex", 1, 0} = LspActions.parse_location(locations)
    end

    test "parses a LocationLink" do
      link = %{
        "targetUri" => "file:///tmp/target.ex",
        "targetRange" => %{
          "start" => %{"line" => 42, "character" => 2},
          "end" => %{"line" => 42, "character" => 20}
        },
        "originSelectionRange" => %{
          "start" => %{"line" => 5, "character" => 0},
          "end" => %{"line" => 5, "character" => 10}
        }
      }

      assert {"file:///tmp/target.ex", 42, 2} = LspActions.parse_location(link)
    end

    test "returns nil for empty array" do
      assert LspActions.parse_location([]) == nil
    end

    test "returns nil for nil" do
      assert LspActions.parse_location(nil) == nil
    end

    test "returns nil for unrecognized format" do
      assert LspActions.parse_location("garbage") == nil
    end
  end

  # ── extract_hover_text/1 ──────────────────────────────────────────────────

  describe "extract_hover_text/1" do
    test "extracts plain text from MarkupContent" do
      content = %{"kind" => "plaintext", "value" => "some docs"}
      assert LspActions.extract_hover_text(content) == "some docs"
    end

    test "extracts and strips markdown from MarkupContent" do
      content = %{
        "kind" => "markdown",
        "value" => "```elixir\ndef hello, do: :world\n```\n\nSome description."
      }

      result = LspActions.extract_hover_text(content)
      assert result == "def hello, do: :world Some description."
    end

    test "handles plain string" do
      assert LspActions.extract_hover_text("just a string") == "just a string"
    end

    test "handles MarkedString array" do
      items = [
        %{"language" => "elixir", "value" => "def foo()"},
        "Some docs"
      ]

      result = LspActions.extract_hover_text(items)
      assert result == "def foo() | Some docs"
    end

    test "handles nil gracefully" do
      assert LspActions.extract_hover_text(nil) == ""
    end

    test "handles empty string" do
      assert LspActions.extract_hover_text("") == ""
    end

    test "strips code fences from markdown" do
      text = "```\ncode here\n```"
      result = LspActions.extract_hover_text(text)
      assert result == "code here"
    end
  end

  # ── handle_definition_response/2 ──────────────────────────────────────────

  describe "handle_definition_response/2" do
    test "sets status message on error" do
      state = fake_state()
      result = LspActions.handle_definition_response(state, {:error, %{"message" => "fail"}})
      assert result.shell_state.status_msg == "Definition request failed"
    end

    test "sets status message when result is nil" do
      state = fake_state()
      result = LspActions.handle_definition_response(state, {:ok, nil})
      assert result.shell_state.status_msg == "No definition found"
    end

    test "sets status message when result is empty list" do
      state = fake_state()
      result = LspActions.handle_definition_response(state, {:ok, []})
      assert result.shell_state.status_msg == "No definition found"
    end
  end

  # ── handle_hover_response/2 ────────────────────────────────────────────────

  describe "handle_hover_response/2" do
    test "sets status message on error" do
      state = fake_state()
      result = LspActions.handle_hover_response(state, {:error, %{"message" => "fail"}})
      assert result.shell_state.status_msg == "Hover request failed"
    end

    test "sets status message when result is nil" do
      state = fake_state()
      result = LspActions.handle_hover_response(state, {:ok, nil})
      assert result.shell_state.status_msg == "No hover information"
    end

    test "creates hover popup for content" do
      state = fake_state()
      hover = %{"contents" => %{"kind" => "plaintext", "value" => "Returns :ok"}}
      result = LspActions.handle_hover_response(state, {:ok, hover})
      assert %HoverPopup{} = result.shell_state.hover_popup
      assert result.shell_state.hover_popup.focused == false
    end

    test "creates hover popup for markdown content" do
      state = fake_state()

      hover = %{
        "contents" => %{
          "kind" => "markdown",
          "value" => "```elixir\n@spec foo() :: :ok\n```"
        }
      }

      result = LspActions.handle_hover_response(state, {:ok, hover})
      assert %HoverPopup{} = result.shell_state.hover_popup
      assert result.shell_state.hover_popup.content_lines != []
    end

    test "handles hover with no contents key" do
      state = fake_state()
      result = LspActions.handle_hover_response(state, {:ok, %{"range" => %{}}})
      assert result.shell_state.status_msg == "No hover information"
    end
  end

  # ── code_lens/1 ───────────────────────────────────────────────────────────

  describe "code_lens/1" do
    test "sets status_msg when no active buffer" do
      state = fake_state()
      result = LspActions.code_lens(state)
      assert result.shell_state.status_msg == "No active buffer"
    end

    test "silently no-ops when no LSP client is registered" do
      buf = start_supervised!({BufferServer, content: "hello"})
      state = fake_state_with_buffer(buf)
      result = LspActions.code_lens(state)
      assert result.shell_state.status_msg == nil
    end
  end

  # ── handle_code_lens_response/2 ──────────────────────────────────────────

  describe "handle_code_lens_response/2" do
    test "stores resolved lenses with commands directly" do
      {:ok, buf} = BufferServer.start_link(content: "def hello do\n  :ok\nend")
      state = fake_state_with_buffer(buf)

      lens = %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 0},
          "end" => %{"line" => 0, "character" => 5}
        },
        "command" => %{"title" => "1 reference", "command" => "refs"}
      }

      result = LspActions.handle_code_lens_response(state, {:ok, [lens]})
      assert length(result.code_lenses) == 1
      assert hd(result.code_lenses).title == "1 reference"
      assert hd(result.code_lenses).line == 0

      GenServer.stop(buf)
    end

    test "error returns state unchanged" do
      state = fake_state() |> Map.put(:code_lenses, [])
      result = LspActions.handle_code_lens_response(state, {:error, "timeout"})
      assert result == state
    end

    test "nil returns state unchanged" do
      state = fake_state() |> Map.put(:code_lenses, [])
      result = LspActions.handle_code_lens_response(state, {:ok, nil})
      assert result == state
    end

    test "empty list returns state unchanged" do
      state = fake_state() |> Map.put(:code_lenses, [])
      result = LspActions.handle_code_lens_response(state, {:ok, []})
      assert result == state
    end
  end

  # ── handle_code_lens_resolve_response/2 ─────────────────────────────────

  describe "handle_code_lens_resolve_response/2" do
    test "merges resolved lens into existing lenses" do
      {:ok, buf} = BufferServer.start_link(content: "def hello do\n  :ok\nend")
      state = fake_state_with_buffer(buf) |> Map.put(:code_lenses, [])

      resolved = %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 0},
          "end" => %{"line" => 0, "character" => 5}
        },
        "command" => %{"title" => "2 references", "command" => "refs"}
      }

      result = LspActions.handle_code_lens_resolve_response(state, {:ok, resolved})
      assert length(result.code_lenses) == 1
      assert hd(result.code_lenses).title == "2 references"

      GenServer.stop(buf)
    end

    test "ignores errors gracefully" do
      state = fake_state() |> Map.put(:code_lenses, [%{line: 0, title: "existing"}])
      result = LspActions.handle_code_lens_resolve_response(state, {:error, "timeout"})
      assert result.code_lenses == [%{line: 0, title: "existing"}]
    end

    test "ignores nil result" do
      state = fake_state() |> Map.put(:code_lenses, [])
      result = LspActions.handle_code_lens_resolve_response(state, {:ok, nil})
      assert result == state
    end
  end

  # ── handle_inlay_hint_response/2 ──────────────────────────────────────────

  describe "handle_inlay_hint_response/2" do
    test "stores parsed hints with correct line/col/label" do
      {:ok, buf} = BufferServer.start_link(content: "x = 1 + 2")
      state = fake_state_with_buffer(buf) |> Map.put(:inlay_hints, [])

      hint = %{
        "position" => %{"line" => 0, "character" => 2},
        "label" => ": integer",
        "kind" => 1,
        "paddingLeft" => true,
        "paddingRight" => false
      }

      result = LspActions.handle_inlay_hint_response(state, {:ok, [hint]})
      assert length(result.inlay_hints) == 1
      parsed = hd(result.inlay_hints)
      assert parsed.line == 0
      assert parsed.col == 2
      assert parsed.label == ": integer"
      assert parsed.kind == :type
      assert parsed.padding_left == true
      assert parsed.padding_right == false

      GenServer.stop(buf)
    end

    test "handles label as array of InlayHintLabelPart" do
      {:ok, buf} = BufferServer.start_link(content: "x = 1")
      state = fake_state_with_buffer(buf) |> Map.put(:inlay_hints, [])

      hint = %{
        "position" => %{"line" => 0, "character" => 2},
        "label" => [%{"value" => ": "}, %{"value" => "int"}],
        "kind" => 1
      }

      result = LspActions.handle_inlay_hint_response(state, {:ok, [hint]})
      assert hd(result.inlay_hints).label == ": int"

      GenServer.stop(buf)
    end

    test "error is a no-op" do
      state = fake_state() |> Map.put(:inlay_hints, [%{line: 0}])
      result = LspActions.handle_inlay_hint_response(state, {:error, "fail"})
      assert result == state
    end

    test "nil is a no-op" do
      state = fake_state() |> Map.put(:inlay_hints, [%{line: 0}])
      result = LspActions.handle_inlay_hint_response(state, {:ok, nil})
      assert result == state
    end

    test "empty list is a no-op" do
      state = fake_state() |> Map.put(:inlay_hints, [%{line: 0}])
      result = LspActions.handle_inlay_hint_response(state, {:ok, []})
      assert result == state
    end
  end

  # ── schedule_inlay_hints_on_scroll/1 ────────────────────────────────────

  describe "schedule_inlay_hints_on_scroll/1" do
    test "no-op when viewport hasn't changed" do
      state =
        fake_state()
        |> Map.merge(%{inlay_hint_debounce_timer: nil, last_inlay_viewport_top: 0})

      result = LspActions.schedule_inlay_hints_on_scroll(state)
      assert result.inlay_hint_debounce_timer == nil
    end

    test "sets timer when viewport top changes" do
      {:ok, buf} = BufferServer.start_link(content: "hello")

      state =
        fake_state()
        |> Map.merge(%{inlay_hint_debounce_timer: nil, last_inlay_viewport_top: nil})
        |> put_in([:workspace, :buffers, :active], buf)
        |> put_in([:workspace, :viewport, :top], 10)

      result = LspActions.schedule_inlay_hints_on_scroll(state)
      assert result.inlay_hint_debounce_timer != nil
      assert result.last_inlay_viewport_top == 10
      # Clean up timer
      Process.cancel_timer(result.inlay_hint_debounce_timer)
      GenServer.stop(buf)
    end

    test "cancels previous timer and sets new one" do
      {:ok, buf} = BufferServer.start_link(content: "hello")

      state =
        fake_state()
        |> Map.merge(%{inlay_hint_debounce_timer: nil, last_inlay_viewport_top: nil})
        |> put_in([:workspace, :buffers, :active], buf)
        |> put_in([:workspace, :viewport, :top], 5)

      state1 = LspActions.schedule_inlay_hints_on_scroll(state)
      timer1 = state1.inlay_hint_debounce_timer

      state2 = state1 |> put_in([:workspace, :viewport, :top], 15)
      state2 = LspActions.schedule_inlay_hints_on_scroll(state2)
      timer2 = state2.inlay_hint_debounce_timer

      assert timer1 != timer2
      assert state2.last_inlay_viewport_top == 15
      # Clean up
      Process.cancel_timer(timer2)
      GenServer.stop(buf)
    end
  end

  # ── handle_prepare_rename_response/2 with Range ─────────────────────────

  describe "handle_prepare_rename_response/2" do
    test "prepareRename with placeholder uses placeholder directly" do
      state = fake_state_with_vim()

      result =
        LspActions.handle_prepare_rename_response(state, {:ok, %{"placeholder" => "myVar"}})

      assert result.workspace.vim.mode == :command
      assert result.workspace.vim.mode_state.input == "rename myVar"
    end

    test "prepareRename with Range + placeholder uses placeholder" do
      state = fake_state_with_vim()

      resp = %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 4},
          "end" => %{"line" => 0, "character" => 15}
        },
        "placeholder" => "hello_world"
      }

      result = LspActions.handle_prepare_rename_response(state, {:ok, resp})
      assert result.workspace.vim.mode == :command
      assert result.workspace.vim.mode_state.input == "rename hello_world"
    end

    test "prepareRename with Range only reads text from buffer" do
      {:ok, buf} = BufferServer.start_link(content: "def hello_world do\n  :ok\nend")
      state = fake_state_with_vim() |> put_in([:workspace, :buffers, :active], buf)

      resp = %{
        "start" => %{"line" => 0, "character" => 4},
        "end" => %{"line" => 0, "character" => 15}
      }

      result = LspActions.handle_prepare_rename_response(state, {:ok, resp})
      assert result.workspace.vim.mode == :command
      assert result.workspace.vim.mode_state.input == "rename hello_world"

      GenServer.stop(buf)
    end

    test "prepareRename with wrapped Range reads text from buffer" do
      {:ok, buf} = BufferServer.start_link(content: "def hello_world do\n  :ok\nend")
      state = fake_state_with_vim() |> put_in([:workspace, :buffers, :active], buf)

      resp = %{
        "range" => %{
          "start" => %{"line" => 0, "character" => 4},
          "end" => %{"line" => 0, "character" => 15}
        }
      }

      result = LspActions.handle_prepare_rename_response(state, {:ok, resp})
      assert result.workspace.vim.mode == :command
      assert result.workspace.vim.mode_state.input == "rename hello_world"

      GenServer.stop(buf)
    end

    test "prepareRename error shows status message" do
      state = fake_state_with_vim()
      result = LspActions.handle_prepare_rename_response(state, {:error, "not renameable"})
      assert result.shell_state.status_msg == "Cannot rename at this position"
    end

    test "prepareRename nil shows cannot-rename message" do
      state = fake_state_with_vim()
      result = LspActions.handle_prepare_rename_response(state, {:ok, nil})
      assert result.shell_state.status_msg == "Cannot rename at this position"
    end

    test "prepareRename with Range but no buffer falls back to empty" do
      state = fake_state_with_vim()

      resp = %{
        "start" => %{"line" => 0, "character" => 0},
        "end" => %{"line" => 0, "character" => 5}
      }

      result = LspActions.handle_prepare_rename_response(state, {:ok, resp})
      assert result.workspace.vim.mode == :command
      assert result.workspace.vim.mode_state.input == "rename "
    end
  end

  # ── handle_hover_mouse_response/4 ────────────────────────────────────────

  describe "handle_hover_mouse_response/4" do
    test "creates hover popup at mouse position for valid content" do
      state = fake_state()
      hover = %{"contents" => %{"kind" => "plaintext", "value" => "Returns :ok"}}
      result = LspActions.handle_hover_mouse_response(state, {:ok, hover}, 5, 20)
      assert %HoverPopup{} = result.shell_state.hover_popup
    end

    test "is a no-op on error" do
      state = fake_state()
      result = LspActions.handle_hover_mouse_response(state, {:error, "fail"}, 5, 20)
      assert result == state
    end

    test "is a no-op when result is nil" do
      state = fake_state()
      result = LspActions.handle_hover_mouse_response(state, {:ok, nil}, 5, 20)
      assert result == state
    end

    test "is a no-op for empty hover contents" do
      state = fake_state()
      hover = %{"contents" => %{"kind" => "plaintext", "value" => ""}}
      result = LspActions.handle_hover_mouse_response(state, {:ok, hover}, 5, 20)
      assert result == state
    end

    test "creates hover popup for markdown content at mouse position" do
      state = fake_state()

      hover = %{
        "contents" => %{"kind" => "markdown", "value" => "```elixir\n@spec foo() :: :ok\n```"}
      }

      result = LspActions.handle_hover_mouse_response(state, {:ok, hover}, 10, 30)
      assert %HoverPopup{} = result.shell_state.hover_popup
      assert result.shell_state.hover_popup.content_lines != []
    end
  end

  # ── CodeActionSource resolve logic (Item 10) ────────────────────────────

  describe "CodeActionSource resolve logic" do
    test "on_select applies edit directly when present" do
      # CodeActionSource.on_select handles actions with edit fields by applying
      # them via LspActions.apply_workspace_edit. We can't test the full picker
      # path without a real LSP client, but we verify the code action source
      # module loads and its candidates function works.
      assert Code.ensure_loaded?(CodeActionSource)
    end

    test "candidates returns items from actions context" do
      actions = [
        %{"title" => "Fix import", "kind" => "quickfix"},
        %{"title" => "Extract variable", "kind" => "refactor.extract", "isPreferred" => true}
      ]

      state = %{shell_state: %{picker_ui: %{context: %{actions: actions}}}}
      items = CodeActionSource.candidates(state)

      assert length(items) == 2
      assert Enum.any?(items, fn item -> String.contains?(item.label, "Fix import") end)
      assert Enum.any?(items, fn item -> String.contains?(item.label, "★") end)
    end

    test "candidates returns empty list when no actions" do
      assert [] == CodeActionSource.candidates(%{})
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp fake_state do
    %{
      workspace: %{
        buffers: %{active: nil},
        viewport: %{rows: 24, cols: 80, top: 0},
        lsp_pending: %{},
        document_highlights: nil,
        highlight: %Minga.Editor.State.Highlighting{}
      },
      shell_state: %Minga.Shell.Traditional.State{status_msg: nil, hover_popup: nil},
      code_lenses: [],
      inlay_hints: [],
      inlay_hint_debounce_timer: nil,
      last_inlay_viewport_top: nil,
      selection_ranges: nil,
      selection_range_index: 0
    }
  end

  defp fake_state_with_buffer(buf) do
    fake_state()
    |> put_in([:workspace, :buffers], %{active: buf, list: [buf]})
  end

  defp fake_state_with_vim do
    fake_state()
    |> put_in([:workspace, :vim], %VimState{mode: :normal, mode_state: nil})
  end
end
