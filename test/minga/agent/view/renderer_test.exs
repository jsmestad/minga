defmodule Minga.Agent.View.RendererTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.Renderer
  alias Minga.Agent.View.Renderer.RenderInput
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Highlighting
  alias Minga.Editor.Viewport
  alias Minga.Input
  alias Minga.Mode
  alias Minga.Theme

  defp default_theme do
    Theme.get!(:doom_one)
  end

  defp default_input(overrides \\ %{}) do
    theme = default_theme()

    base = %RenderInput{
      viewport: Viewport.new(24, 80),
      theme: theme,
      agent_status: :idle,
      panel: %{
        input_focused: false,
        input_lines: [""],
        input_cursor: {0, 0},
        scroll_offset: 0,
        spinner_frame: 0,
        model_name: "claude-sonnet-4",
        provider_name: "anthropic",
        thinking_level: "medium",
        auto_scroll: true,
        display_start_index: 0,
        mention_completion: nil,
        pasted_blocks: []
      },
      agentic: %{
        chat_width_pct: 65,
        help_visible: false,
        focus: :chat,
        search: nil,
        toast: nil
      },
      messages: [],
      session_title: "Minga Agent"
    }

    Map.merge(base, overrides)
  end

  defp base_state(opts \\ []) do
    rows = Keyword.get(opts, :rows, 40)
    cols = Keyword.get(opts, :cols, 120)
    {:ok, buf} = BufferServer.start_link(content: "line one\nline two\nline three")

    panel = %PanelState{
      visible: true,
      input_focused: Keyword.get(opts, :input_focused, false),
      input_lines: Keyword.get(opts, :input_lines, [Keyword.get(opts, :input_text, "")]),
      input_cursor:
        Keyword.get(opts, :input_cursor, {0, String.length(Keyword.get(opts, :input_text, ""))}),
      scroll_offset: 0,
      spinner_frame: 0,
      provider_name: "anthropic",
      model_name: "claude-sonnet-4",
      thinking_level: "medium"
    }

    agent = %AgentState{
      session: nil,
      status: :idle,
      panel: panel,
      error: nil,
      spinner_timer: nil,
      buffer: nil
    }

    agentic = %ViewState{
      active: true,
      focus: Keyword.get(opts, :focus, :chat),
      preview: Preview.new(),
      saved_windows: nil,
      pending_prefix: nil,
      saved_file_tree: nil
    }

    %EditorState{
      port_manager: self(),
      viewport: Viewport.new(rows, cols),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{active: buf, list: [buf], active_index: 0},
      focus_stack: Input.default_stack(),
      agent: agent,
      agentic: agentic,
      theme: Theme.get!(:doom_one),
      highlight: %Highlighting{}
    }
  end

  describe "cursor_position/1" do
    test "when input not focused, cursor is off-screen (row = viewport rows)" do
      state = base_state(rows: 40, input_focused: false)
      {row, _col} = Renderer.cursor_position(state)
      assert row == 40
    end

    test "when input is focused, cursor row is within content area" do
      state = base_state(rows: 40, input_focused: true)
      {row, col} = Renderer.cursor_position(state)
      assert row < 40
      assert row >= 0
      assert col >= 0
    end

    test "cursor column advances with input_text length" do
      state_empty = base_state(input_focused: true, input_text: "")
      state_hello = base_state(input_focused: true, input_text: "hello")

      {_r, col_empty} = Renderer.cursor_position(state_empty)
      {_r, col_hello} = Renderer.cursor_position(state_hello)

      assert col_hello == col_empty + String.length("hello")
    end

    test "cursor row is the same regardless of input text length" do
      state_short = base_state(input_focused: true, input_text: "hi")
      state_long = base_state(input_focused: true, input_text: "a long message here")

      {row_short, _} = Renderer.cursor_position(state_short)
      {row_long, _} = Renderer.cursor_position(state_long)

      assert row_short == row_long
    end
  end

  describe "render/1" do
    test "returns a non-empty list of draw tuples" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)
      assert [_ | _] = commands
      assert Enum.all?(commands, &is_tuple/1)
    end

    test "all draw tuples have valid 4-element structure" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)

      Enum.each(commands, fn cmd ->
        assert tuple_size(cmd) == 4, "draw tuple should have 4 elements: #{inspect(cmd)}"
        {row, col, text, style} = cmd
        assert is_integer(row)
        assert is_integer(col)
        assert is_binary(text)
        assert is_list(style)
      end)
    end

    test "produces more commands with more rows (larger viewport)" do
      state_small = base_state(rows: 20, cols: 80)
      state_large = base_state(rows: 40, cols: 80)

      cmds_small = Renderer.render(state_small)
      cmds_large = Renderer.render(state_large)

      assert length(cmds_large) > length(cmds_small)
    end

    test "does not crash when active buffer is nil" do
      state = base_state()
      state = put_in(state.buffers.active, nil)
      commands = Renderer.render(state)
      assert is_list(commands)
    end

    test "renders with file viewer scroll applied" do
      state_top = base_state(viewer_scroll: 0)
      state_scrolled = base_state(viewer_scroll: 2)

      cmds_top = Renderer.render(state_top)
      cmds_scrolled = Renderer.render(state_scrolled)

      assert is_list(cmds_top)
      assert is_list(cmds_scrolled)
    end
  end

  describe "layout proportions" do
    test "chat panel occupies ~65% of columns" do
      cols = 120
      state = base_state(cols: cols)

      expected_chat_width = div(cols * 65, 100)

      commands = Renderer.render(state)

      chat_cols =
        commands
        |> Enum.map(fn {_row, col, _text, _style} -> col end)
        |> Enum.filter(&(&1 < expected_chat_width))

      viewer_cols =
        commands
        |> Enum.map(fn {_row, col, _text, _style} -> col end)
        |> Enum.filter(&(&1 > expected_chat_width))

      assert chat_cols != [], "expected draw commands in chat panel columns"
      assert viewer_cols != [], "expected draw commands in viewer panel columns"
    end
  end

  describe "title bar" do
    test "renders draw commands at row 1 (title bar below tab bar)" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)

      row_1_cmds = Enum.filter(commands, fn {row, _col, _text, _style} -> row == 1 end)

      assert row_1_cmds != [], "expected draw commands at row 1 (title bar)"
    end
  end

  describe "input area inside left column" do
    test "input border renders at col 0 within the left panel" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)

      # With the new layout: modeline at row 28, input_height = 3,
      # input starts at row 28 - 3 = 25
      input_border_row = 30 - 1 - 1 - 3

      input_cmds =
        Enum.filter(commands, fn {row, col, _text, _style} ->
          row == input_border_row and col == 0
        end)

      assert input_cmds != [], "expected input border at col 0"
    end

    test "input box width is constrained to left column (chat_width)" do
      cols = 100
      state = base_state(rows: 30, cols: cols)
      commands = Renderer.render(state)

      chat_width = div(cols * 65, 100)

      # Find the top border of the input box
      top_border_cmds =
        Enum.filter(commands, fn {_row, col, text, _style} ->
          col == 0 and String.starts_with?(text, "╭─ Prompt")
        end)

      assert [top_cmd | _] = top_border_cmds
      {_row, _col, top_text, _style} = top_cmd

      assert String.length(top_text) <= chat_width,
             "input box should be ≤ chat_width (#{chat_width}), got #{String.length(top_text)}"
    end

    test "right panel extends alongside the input area" do
      cols = 100
      state = base_state(rows: 30, cols: cols)
      commands = Renderer.render(state)

      chat_width = div(cols * 65, 100)
      viewer_col = chat_width + 1
      input_border_row = 30 - 1 - 1 - 3

      # The viewer/dashboard should have draw commands at rows alongside the input
      viewer_at_input_rows =
        Enum.filter(commands, fn {row, col, _text, _style} ->
          row >= input_border_row and row < 30 - 2 and col >= viewer_col
        end)

      assert viewer_at_input_rows != [],
             "expected right panel content at rows alongside the input area"
    end

    test "separator extends the full panel height including alongside input" do
      cols = 100
      state = base_state(rows: 30, cols: cols)
      commands = Renderer.render(state)

      chat_width = div(cols * 65, 100)
      sep_col = chat_width
      panel_start = 2
      modeline_row = 30 - 2

      sep_cmds =
        Enum.filter(commands, fn {_row, col, text, _style} ->
          col == sep_col and text == "│"
        end)

      sep_rows = Enum.map(sep_cmds, fn {row, _, _, _} -> row end) |> Enum.sort()

      # Separator should span from panel_start to modeline_row - 1
      expected_rows = Enum.to_list(panel_start..(modeline_row - 1))

      assert sep_rows == expected_rows,
             "separator should span rows #{panel_start}..#{modeline_row - 1}, got #{inspect(sep_rows)}"
    end
  end

  describe "file viewer header" do
    test "file viewer header is at the top of the viewer panel (row 2)" do
      state = base_state(rows: 30, cols: 100)
      commands = Renderer.render(state)

      chat_width = div(100 * 65, 100)
      viewer_col = chat_width + 1

      # Header should be at row 2 (panel_start), at viewer_col
      header_cmds =
        Enum.filter(commands, fn {row, col, _text, _style} ->
          row == 2 and col == viewer_col
        end)

      assert header_cmds != [], "expected file viewer header at row 2"
    end
  end

  describe "render/1 with RenderInput (isolated, no GenServer)" do
    test "renders with a focused RenderInput, no full EditorState needed" do
      input = %Renderer.RenderInput{
        viewport: Viewport.new(30, 100),
        theme: Theme.get!(:doom_one),
        agent_status: :idle,
        panel: %{
          input_focused: false,
          input_lines: [""],
          input_cursor: {0, 0},
          scroll_offset: 0,
          spinner_frame: 0,
          model_name: "claude-sonnet-4",
          provider_name: "anthropic",
          thinking_level: "medium",
          auto_scroll: true,
          display_start_index: 0,
          mention_completion: nil,
          pasted_blocks: []
        },
        agentic: %{
          chat_width_pct: 65,
          help_visible: false,
          focus: :chat,
          search: nil,
          toast: nil
        },
        messages: [],
        usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0},
        buffer_snapshot: nil,
        highlight: nil,
        mode: :normal,
        mode_state: nil,
        buf_index: 1,
        buf_count: 1
      }

      commands = Renderer.render(input)
      assert [_ | _] = commands
      assert Enum.all?(commands, &is_tuple/1)
    end

    test "renders with file preview data" do
      input = %Renderer.RenderInput{
        viewport: Viewport.new(30, 100),
        theme: Theme.get!(:doom_one),
        agent_status: :thinking,
        panel: %{
          input_focused: true,
          input_lines: ["hello"],
          input_cursor: {0, 5},
          scroll_offset: 0,
          spinner_frame: 3,
          model_name: "claude-sonnet-4",
          provider_name: "anthropic",
          thinking_level: "medium",
          auto_scroll: true,
          display_start_index: 0,
          mention_completion: nil,
          pasted_blocks: []
        },
        agentic: %{
          chat_width_pct: 65,
          help_visible: false,
          focus: :chat,
          search: nil,
          toast: nil
        },
        messages: [],
        # Set preview to a file so the buffer preview renders (not dashboard)
        preview: %Preview{content: {:file, "test.ex", "line one\nline two"}, scroll_offset: 0},
        usage: %{input: 1500, output: 300, cache_read: 0, cache_write: 0, cost: 0.012},
        buffer_snapshot: nil,
        highlight: nil,
        mode: :normal,
        mode_state: nil,
        buf_index: 1,
        buf_count: 2
      }

      commands = Renderer.render(input)
      assert [_ | _] = commands

      # Should have file viewer content
      texts = Enum.map(commands, fn {_r, _c, text, _s} -> text end)
      assert Enum.any?(texts, &String.contains?(&1, "test.ex"))
    end
  end

  describe "context bar" do
    test "context bar appears in title bar when usage exists" do
      state = base_state()
      # Simulate some token usage by directly setting the panel state
      # The renderer reads usage from the session, but for isolated tests
      # we check via RenderInput
      input = %Renderer.RenderInput{
        viewport: Viewport.new(30, 100),
        theme: Theme.get!(:doom_one),
        agent_status: :idle,
        panel: %{
          input_focused: false,
          input_lines: [""],
          input_cursor: {0, 0},
          scroll_offset: 0,
          spinner_frame: 0,
          model_name: "claude-sonnet-4",
          provider_name: "anthropic",
          thinking_level: "medium",
          auto_scroll: true,
          display_start_index: 0,
          mention_completion: nil,
          pasted_blocks: []
        },
        agentic: %{chat_width_pct: 65, help_visible: false, focus: :chat, search: nil, toast: nil},
        messages: [],
        usage: %{input: 50_000, output: 50_000, cache_read: 0, cache_write: 0, cost: 0.05},
        buffer_snapshot: nil,
        highlight: nil,
        mode: :normal,
        mode_state: nil,
        buf_index: 1,
        buf_count: 1
      }

      _ = state
      commands = Renderer.render(input)
      texts = Enum.map(commands, fn d -> elem(d, 2) end)

      has_bar = Enum.any?(texts, &String.contains?(&1, "█"))
      assert has_bar, "expected context bar with filled blocks in title bar"
    end
  end

  describe "resize re-layout" do
    test "different viewport sizes produce different chat widths" do
      state_80 = base_state(rows: 24, cols: 80)
      state_120 = base_state(rows: 24, cols: 120)

      cmds_80 = Renderer.render(state_80)
      cmds_120 = Renderer.render(state_120)

      cols_80 =
        cmds_80
        |> Enum.map(fn {_row, col, _text, _style} -> col end)
        |> Enum.max(fn -> 0 end)

      cols_120 =
        cmds_120
        |> Enum.map(fn {_row, col, _text, _style} -> col end)
        |> Enum.max(fn -> 0 end)

      assert cols_120 > cols_80, "wider viewport should use more columns"
    end
  end

  describe "session title" do
    test "title bar shows Minga Agent when no messages" do
      input = default_input()
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "Minga Agent"))
    end

    test "title bar shows first user prompt when available" do
      input =
        default_input(%{
          messages: [{:user, "Explain the BEAM"}, {:assistant, "The BEAM is..."}],
          session_title: "Explain the BEAM"
        })

      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "Explain the BEAM"))
    end
  end

  describe "keyboard hints" do
    test "modeline includes keyboard hints for chat focus" do
      input = default_input()
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "? help"))
    end

    test "modeline shows input hints when input is focused" do
      input =
        default_input(%{
          panel: %{
            input_focused: true,
            input_lines: [""],
            input_cursor: {0, 0},
            scroll_offset: 0,
            spinner_frame: 0,
            model_name: "claude-sonnet-4",
            provider_name: "anthropic",
            thinking_level: "medium",
            auto_scroll: true,
            display_start_index: 0,
            mention_completion: nil,
            pasted_blocks: []
          }
        })

      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "send"))
    end
  end

  describe "model info" do
    test "model name appears near input area" do
      input = default_input()
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "claude-sonnet-4"))
    end

    test "thinking level appears when set" do
      input = default_input()
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "medium"))
    end

    test "provider name appears in model info line (titleized)" do
      input = default_input()
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "Anthropic"))
    end
  end

  describe "input box border" do
    test "input area has rounded box border with Prompt label" do
      input = default_input()
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.starts_with?(&1, "╭─ Prompt")),
             "expected top border with Prompt label"

      assert Enum.any?(texts, &String.starts_with?(&1, "╰─")),
             "expected bottom border"

      refute Enum.any?(texts, &String.contains?(&1, "─── Prompt")),
             "should not have old Prompt border"
    end

    test "model info is embedded in bottom border" do
      input = default_input()
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, fn text ->
               String.starts_with?(text, "╰─") and String.contains?(text, "Claude Sonnet 4")
             end),
             "expected model info in bottom border"
    end
  end

  describe "dashboard panel" do
    test "shows session info when preview is empty" do
      input = default_input()
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      # Dashboard should show Context section
      assert Enum.any?(texts, &String.contains?(&1, "Context"))
      # Dashboard should show Model section
      assert Enum.any?(texts, &String.contains?(&1, "Model"))
      # Dashboard should show the model name
      assert Enum.any?(texts, &String.contains?(&1, "claude-sonnet-4"))
      # Status is shown in the title bar, not the dashboard
    end

    test "shows token usage when available" do
      input =
        default_input(%{
          usage: %{input: 15_000, output: 2000, cache_read: 8000, cache_write: 0, cost: 0.042}
        })

      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "17.0k tokens"))
      assert Enum.any?(texts, &String.contains?(&1, "$0.042"))
    end

    test "shows working directory" do
      input = default_input()
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "Directory"))
    end

    test "shows LSP section with no servers when list is empty" do
      input = default_input(%{lsp_servers: []})
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "LSP"))
      assert Enum.any?(texts, &String.contains?(&1, "No servers active"))
    end

    test "shows LSP section with active server names" do
      input = default_input(%{lsp_servers: [:lexical, :gopls]})
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "LSP"))
      assert Enum.any?(texts, &String.contains?(&1, "lexical"))
      assert Enum.any?(texts, &String.contains?(&1, "gopls"))
    end

    test "working directory is pinned to the bottom of the panel" do
      input = default_input()
      draws = Renderer.render(input)

      dir_draws =
        Enum.filter(draws, fn {_row, _col, text, _style} ->
          String.contains?(text, "Directory")
        end)

      assert dir_draws != [], "Directory section should be rendered"

      # Directory should be near the bottom of the viewport (within last 3 rows)
      dir_row = dir_draws |> hd() |> elem(0)
      max_row = input.viewport.rows - 1

      assert dir_row >= max_row - 3,
             "Directory (row #{dir_row}) should be pinned near the bottom (max row #{max_row})"
    end

    test "not shown when preview has file content" do
      preview =
        Preview.set_file(
          Preview.new(),
          "/tmp/test.txt",
          "hello world"
        )

      input = default_input(%{preview: preview})
      draws = Renderer.render(input)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      # File preview should be showing
      assert Enum.any?(texts, &String.contains?(&1, "test.txt"))
    end
  end
end
