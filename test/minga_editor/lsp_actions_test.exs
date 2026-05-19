defmodule MingaEditor.LspActionsTest do
  @moduledoc "Tests for public LspActions parsing, response handling, and picker source behavior."

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.HoverPopup
  alias MingaEditor.LspActions
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Highlighting
  alias MingaEditor.UI.Picker.CodeActionSource
  alias MingaEditor.UI.Picker.Context, as: PickerContext
  alias MingaEditor.VimState
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  describe "parse_location/1" do
    test "extracts the first target URI and start position from supported LSP shapes" do
      cases = [
        {location("file:///tmp/foo.ex", 10, 5), {"file:///tmp/foo.ex", 10, 5}},
        {[location("file:///tmp/first.ex", 1, 0), location("file:///tmp/second.ex", 20, 3)],
         {"file:///tmp/first.ex", 1, 0}},
        {%{
           "targetUri" => "file:///tmp/target.ex",
           "targetRange" => %{
             "start" => %{"line" => 42, "character" => 2},
             "end" => %{"line" => 42, "character" => 20}
           },
           "originSelectionRange" => %{
             "start" => %{"line" => 5, "character" => 0},
             "end" => %{"line" => 5, "character" => 10}
           }
         }, {"file:///tmp/target.ex", 42, 2}}
      ]

      for {input, expected} <- cases do
        assert LspActions.parse_location(input) == expected
      end
    end

    test "returns nil for unsupported location responses" do
      for input <- [[], nil, "garbage"] do
        assert LspActions.parse_location(input) == nil
      end
    end
  end

  describe "extract_hover_text/1" do
    test "normalizes hover content from supported LSP shapes" do
      cases = [
        {%{"kind" => "plaintext", "value" => "some docs"}, "some docs"},
        {%{
           "kind" => "markdown",
           "value" => "```elixir\ndef hello, do: :world\n```\n\nSome description."
         }, "def hello, do: :world Some description."},
        {"just a string", "just a string"},
        {[%{"language" => "elixir", "value" => "def foo()"}, "Some docs"],
         "def foo() | Some docs"},
        {nil, ""},
        {"", ""},
        {"```\ncode here\n```", "code here"}
      ]

      for {input, expected} <- cases do
        assert LspActions.extract_hover_text(input) == expected
      end
    end
  end

  describe "definition and hover responses" do
    test "definition response reports errors and empty results" do
      cases = [
        {{:error, %{"message" => "fail"}}, "Definition request failed"},
        {{:ok, nil}, "No definition found"},
        {{:ok, []}, "No definition found"}
      ]

      for {response, expected_status} <- cases do
        result = LspActions.handle_definition_response(fake_state(), response)
        assert result.shell_state.status_msg == expected_status
      end
    end

    @tag :tmp_dir
    test "peek definition opens a focused popup with source preview and open action", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "peek_target.ex")
      File.write!(path, "defmodule Example do\n  def target do\n    :ok\n  end\nend\n")

      uri = "file://#{path}"

      result =
        LspActions.handle_peek_definition_response(
          fake_state(),
          {:ok, location(uri, 1, 6)}
        )

      assert %HoverPopup{focused: true, open_action: {:goto_location, ^uri, 1, 6}} =
               result.shell_state.hover_popup
    end

    test "hover response reports empty results or creates an unfocused popup" do
      empty_cases = [
        {{:error, %{"message" => "fail"}}, "Hover request failed"},
        {{:ok, nil}, "No hover information"},
        {{:ok, %{"range" => %{}}}, "No hover information"}
      ]

      for {response, expected_status} <- empty_cases do
        assert LspActions.handle_hover_response(fake_state(), response).shell_state.status_msg ==
                 expected_status
      end

      for hover <- [
            %{"contents" => %{"kind" => "plaintext", "value" => "Returns :ok"}},
            %{
              "contents" => %{
                "kind" => "markdown",
                "value" => "```elixir\n@spec foo() :: :ok\n```"
              }
            }
          ] do
        result = LspActions.handle_hover_response(fake_state(), {:ok, hover})
        assert %HoverPopup{focused: false} = result.shell_state.hover_popup
        assert result.shell_state.hover_popup.content_lines != []
      end
    end

    test "mouse hover creates positioned popup for content and no-ops for empty responses" do
      plaintext = %{"contents" => %{"kind" => "plaintext", "value" => "Returns :ok"}}

      markdown = %{
        "contents" => %{"kind" => "markdown", "value" => "```elixir\n@spec foo() :: :ok\n```"}
      }

      for hover <- [plaintext, markdown] do
        result = LspActions.handle_hover_mouse_response(fake_state(), {:ok, hover}, 5, 20)
        assert %HoverPopup{} = result.shell_state.hover_popup
        assert result.shell_state.hover_popup.content_lines != []
      end

      for response <- [
            {:error, "fail"},
            {:ok, nil},
            {:ok, %{"contents" => %{"kind" => "plaintext", "value" => ""}}}
          ] do
        state = fake_state()
        assert LspActions.handle_hover_mouse_response(state, response, 5, 20) == state
      end
    end
  end

  describe "code lens responses" do
    test "code_lens reports missing buffers and no-ops when no client is registered" do
      assert LspActions.code_lens(fake_state()).shell_state.status_msg == "No active buffer"

      state = fake_state_with_buffer(start_buffer!("hello"))
      assert LspActions.code_lens(state).shell_state.status_msg == nil
    end

    test "stores resolved lenses with commands directly" do
      state = fake_state_with_buffer(start_buffer!("def hello do\n  :ok\nend"))
      result = LspActions.handle_code_lens_response(state, {:ok, [code_lens("1 reference")]})

      assert [%{title: "1 reference", line: 0}] = result.lsp.code_lenses
    end

    test "code lens response leaves state unchanged for empty or failed responses" do
      for response <- [{:error, "timeout"}, {:ok, nil}, {:ok, []}] do
        state = fake_state()
        assert LspActions.handle_code_lens_response(state, response) == state
      end
    end

    test "resolve response merges commands and preserves existing lenses on ignored responses" do
      state = fake_state_with_buffer(start_buffer!("def hello do\n  :ok\nend"))
      resolved = code_lens("2 references")

      result = LspActions.handle_code_lens_resolve_response(state, {:ok, resolved})
      assert [%{title: "2 references"}] = result.lsp.code_lenses

      existing_state = fake_state()

      existing_state =
        put_in(
          existing_state.lsp,
          MingaEditor.State.LSP.set_code_lenses(existing_state.lsp, [
            %{line: 0, title: "existing"}
          ])
        )

      assert LspActions.handle_code_lens_resolve_response(existing_state, {:error, "timeout"}).lsp.code_lenses ==
               [%{line: 0, title: "existing"}]

      state = fake_state()
      assert LspActions.handle_code_lens_resolve_response(state, {:ok, nil}) == state
    end
  end

  describe "inlay hints" do
    test "stores parsed hints from string labels and label parts" do
      state = fake_state_with_buffer(start_buffer!("x = 1 + 2"))

      hints = [
        %{
          "position" => %{"line" => 0, "character" => 2},
          "label" => ": integer",
          "kind" => 1,
          "paddingLeft" => true,
          "paddingRight" => false
        },
        %{
          "position" => %{"line" => 0, "character" => 4},
          "label" => [%{"value" => ": "}, %{"value" => "int"}],
          "kind" => 1
        }
      ]

      result = LspActions.handle_inlay_hint_response(state, {:ok, hints})

      assert [first, second] = result.lsp.inlay_hints

      assert %{
               line: 0,
               col: 2,
               label: ": integer",
               kind: :type,
               padding_left: true,
               padding_right: false
             } = first

      assert second.label == ": int"
    end

    test "leaves existing hints unchanged for empty or failed responses" do
      for response <- [{:error, "fail"}, {:ok, nil}, {:ok, []}] do
        state = fake_state()
        state = put_in(state.lsp, MingaEditor.State.LSP.set_inlay_hints(state.lsp, [%{line: 0}]))
        assert LspActions.handle_inlay_hint_response(state, response) == state
      end
    end

    test "schedules hints only when a Zig viewport changes, replacing existing timers" do
      state = fake_state()
      state = put_in(state.lsp, %{state.lsp | last_inlay_viewport_top: 0})
      assert LspActions.schedule_inlay_hints_on_scroll(state).lsp.inlay_hint_debounce_timer == nil

      headless_state = state_with_active_buffer(fake_state(), start_buffer!("hello"), top: 10)

      assert LspActions.schedule_inlay_hints_on_scroll(headless_state).lsp.inlay_hint_debounce_timer ==
               nil

      zig_state = %{
        state_with_active_buffer(fake_state(), start_buffer!("hello"), top: 5)
        | backend: :zig
      }

      scheduled = LspActions.schedule_inlay_hints_on_scroll(zig_state)
      first_timer = scheduled.lsp.inlay_hint_debounce_timer
      assert first_timer != nil
      assert scheduled.lsp.last_inlay_viewport_top == 5

      rescheduled =
        LspActions.schedule_inlay_hints_on_scroll(%{
          scheduled
          | terminal_viewport: %{scheduled.terminal_viewport | top: 15}
        })

      assert rescheduled.lsp.inlay_hint_debounce_timer != first_timer
      assert rescheduled.lsp.last_inlay_viewport_top == 15
      Process.cancel_timer(rescheduled.lsp.inlay_hint_debounce_timer)
    end
  end

  describe "prepare rename response" do
    test "opens rename command with placeholders or range text" do
      cases = [
        {{:ok, %{"placeholder" => "myVar"}}, nil, "rename myVar"},
        {{:ok, %{"range" => range(0, 4, 15), "placeholder" => "hello_world"}}, nil,
         "rename hello_world"},
        {{:ok, flat_range(0, 4, 15)}, "def hello_world do\n  :ok\nend", "rename hello_world"},
        {{:ok, %{"range" => range(0, 4, 15)}}, "def hello_world do\n  :ok\nend",
         "rename hello_world"},
        {{:ok, flat_range(0, 0, 5)}, nil, "rename "}
      ]

      for {response, buffer_content, expected_input} <- cases do
        state =
          if buffer_content,
            do: fake_state_with_buffer(start_buffer!(buffer_content)),
            else: fake_state_with_vim()

        state = %{state | workspace: %{state.workspace | editing: VimState.new()}}
        result = LspActions.handle_prepare_rename_response(state, response)

        assert result.workspace.editing.mode == :command
        assert result.workspace.editing.mode_state.input == expected_input
      end
    end

    test "reports cannot-rename for failed responses" do
      for response <- [{:error, "not renameable"}, {:ok, nil}] do
        result = LspActions.handle_prepare_rename_response(fake_state_with_vim(), response)
        assert result.shell_state.status_msg == "Cannot rename at this position"
      end
    end
  end

  describe "CodeActionSource" do
    test "candidates expose quickfix labels, preferred marker, and empty context behavior" do
      actions = [
        %{"title" => "Fix import", "kind" => "quickfix"},
        %{"title" => "Extract variable", "kind" => "refactor.extract", "isPreferred" => true}
      ]

      items = CodeActionSource.candidates(picker_context(actions))

      assert length(items) == 2
      assert Enum.any?(items, fn item -> String.contains?(item.label, "Fix import") end)
      assert Enum.any?(items, fn item -> String.contains?(item.label, "★") end)
      assert CodeActionSource.candidates(%{}) == []
    end
  end

  defp location(uri, line, character) do
    %{
      "uri" => uri,
      "range" => %{
        "start" => %{"line" => line, "character" => character},
        "end" => %{"line" => line, "character" => character + 10}
      }
    }
  end

  defp range(line, start_col, end_col) do
    %{
      "start" => %{"line" => line, "character" => start_col},
      "end" => %{"line" => line, "character" => end_col}
    }
  end

  defp flat_range(line, start_col, end_col) do
    %{
      "start" => %{"line" => line, "character" => start_col},
      "end" => %{"line" => line, "character" => end_col}
    }
  end

  defp code_lens(title) do
    %{
      "range" => range(0, 0, 5),
      "command" => %{"title" => title, "command" => "refs"}
    }
  end

  defp start_buffer!(content) do
    {:ok, pid} = BufferProcess.start_link(content: content)
    on_exit(fn -> Process.exit(pid, :normal) end)
    pid
  end

  defp state_with_active_buffer(state, buf, opts) do
    top = Keyword.fetch!(opts, :top)
    state = %{state | workspace: %{state.workspace | buffers: %Buffers{active: buf, list: [buf]}}}
    %{state | terminal_viewport: %{state.terminal_viewport | top: top}}
  end

  defp picker_context(actions) do
    tab = MingaEditor.State.Tab.new_file(1, "test")

    %PickerContext{
      buffers: %Buffers{},
      editing: VimState.new(),
      search: %MingaEditor.State.Search{},
      viewport: Viewport.new(24, 80),
      tab_bar: MingaEditor.State.TabBar.new(tab),
      picker_ui: %{context: %{actions: actions}},
      capabilities: %{},
      theme: MingaEditor.UI.Theme.get!(:doom_one)
    }
  end

  defp fake_state do
    viewport = Viewport.new(24, 80)

    %EditorState{
      port_manager: nil,
      terminal_viewport: viewport,
      workspace: %WorkspaceState{viewport: viewport, highlight: %Highlighting{}}
    }
  end

  defp fake_state_with_buffer(buf) do
    state = fake_state()
    %{state | workspace: %{state.workspace | buffers: %Buffers{active: buf, list: [buf]}}}
  end

  defp fake_state_with_vim do
    state = fake_state()
    %{state | workspace: %{state.workspace | editing: VimState.new()}}
  end
end
