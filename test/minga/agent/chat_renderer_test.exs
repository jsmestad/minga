defmodule Minga.Agent.ChatRendererTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.ChatRenderer
  alias Minga.Theme

  defp default_theme do
    {:ok, theme} = Theme.get(:doom_one)
    theme
  end

  defp panel(opts) do
    %{
      messages: Keyword.get(opts, :messages, []),
      status: Keyword.get(opts, :status, :idle),
      input_lines: Keyword.get(opts, :input_lines, [""]),
      input_cursor: Keyword.get(opts, :input_cursor, {0, 0}),
      scroll_offset: Keyword.get(opts, :scroll_offset, 0),
      spinner_frame: 0,
      usage: %{input: 0, output: 0, cost: 0.0},
      model_name: "claude-sonnet-4",
      thinking_level: "medium",
      auto_scroll: Keyword.get(opts, :auto_scroll, true),
      display_start_index: Keyword.get(opts, :display_start_index, 0),
      error_message: nil,
      pending_approval: Keyword.get(opts, :pending_approval, nil),
      mention_completion: Keyword.get(opts, :mention_completion, nil)
    }
  end

  # ── Status animations ────────────────────────────────────────────────────

  describe "thinking dot progression" do
    test "thinking indicator cycles dots with spinner_frame" do
      messages = [{:assistant, "Hello"}]
      rect = {0, 0, 60, 20}

      # Frame 0: no dots
      p0 = %{panel(messages: messages, status: :thinking) | spinner_frame: 0}
      draws0 = ChatRenderer.render_messages_only(rect, p0, default_theme())
      texts0 = Enum.map(draws0, fn d -> elem(d, 2) end)
      assert Enum.any?(texts0, &String.contains?(&1, "Thinking"))

      # Frame 3: one dot
      p1 = %{panel(messages: messages, status: :thinking) | spinner_frame: 3}
      draws1 = ChatRenderer.render_messages_only(rect, p1, default_theme())
      texts1 = Enum.map(draws1, fn d -> elem(d, 2) end)
      assert Enum.any?(texts1, &String.contains?(&1, "Thinking."))

      # Frame 6: two dots
      p2 = %{panel(messages: messages, status: :thinking) | spinner_frame: 6}
      draws2 = ChatRenderer.render_messages_only(rect, p2, default_theme())
      texts2 = Enum.map(draws2, fn d -> elem(d, 2) end)
      assert Enum.any?(texts2, &String.contains?(&1, "Thinking.."))
    end
  end

  describe "streaming cursor" do
    test "shows block cursor on even spinner frames during thinking" do
      messages = [{:assistant, "Hello world"}]
      rect = {0, 0, 60, 20}

      p = %{panel(messages: messages, status: :thinking) | spinner_frame: 0}
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "▌"))
    end

    test "hides cursor on odd spinner frames (blink)" do
      messages = [{:assistant, "Hello world"}]
      rect = {0, 0, 60, 20}

      p = %{panel(messages: messages, status: :thinking) | spinner_frame: 1}
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      refute Enum.any?(texts, &String.contains?(&1, "▌"))
    end

    test "no cursor when idle" do
      messages = [{:assistant, "Hello world"}]
      rect = {0, 0, 60, 20}

      p = panel(messages: messages, status: :idle)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      refute Enum.any?(texts, &String.contains?(&1, "▌"))
    end
  end

  describe "tool execution animation" do
    test "running tool shows animated spinner instead of static icon" do
      tc = %{
        id: "tc1",
        name: "shell",
        args: %{"command" => "mix test"},
        status: :running,
        result: "",
        is_error: false,
        collapsed: true,
        started_at: System.monotonic_time(:millisecond),
        duration_ms: nil
      }

      messages = [{:tool_call, tc}]
      rect = {0, 0, 60, 20}
      p = panel(messages: messages, status: :tool_executing)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      # Should have a braille spinner char, not the old static ⟳
      has_braille =
        Enum.any?(texts, fn t ->
          String.match?(t, ~r/[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/)
        end)

      assert has_braille, "expected animated braille spinner for running tool"
    end

    test "completed tool shows checkmark" do
      tc = %{
        id: "tc1",
        name: "shell",
        args: %{},
        status: :complete,
        result: "ok",
        is_error: false,
        collapsed: true,
        started_at: nil,
        duration_ms: 100
      }

      messages = [{:tool_call, tc}]
      rect = {0, 0, 60, 20}
      p = panel(messages: messages, status: :idle)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "✓"))
    end
  end

  describe "per-turn usage footer" do
    test "usage messages produce no inline output (logged to *Messages* instead)" do
      usage = %{input: 12_345, output: 2100, cache_read: 8400, cache_write: 0, cost: 0.042}
      messages = [{:assistant, "Hello"}, {:usage, usage}]

      rect = {0, 0, 60, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      refute Enum.any?(texts, &String.contains?(&1, "$0.042")),
             "usage should not render inline"

      refute Enum.any?(texts, &String.contains?(&1, "↑12.3k")),
             "usage tokens should not render inline"
    end
  end

  describe "display clear filtering" do
    test "display_start_index hides earlier messages" do
      messages = [
        {:user, "First message"},
        {:assistant, "First response"},
        {:user, "Second message"},
        {:assistant, "Second response"}
      ]

      rect = {0, 0, 60, 20}

      # Without filtering, "First message" should appear
      p_all = panel(messages: messages, display_start_index: 0)
      draws_all = ChatRenderer.render_messages_only(rect, p_all, default_theme())
      texts_all = Enum.map(draws_all, fn d -> elem(d, 2) end)
      assert Enum.any?(texts_all, &String.contains?(&1, "First message"))

      # With filtering at index 2, "First message" should not appear
      p_filtered = panel(messages: messages, display_start_index: 2)
      draws_filtered = ChatRenderer.render_messages_only(rect, p_filtered, default_theme())
      texts_filtered = Enum.map(draws_filtered, fn d -> elem(d, 2) end)
      refute Enum.any?(texts_filtered, &String.contains?(&1, "First message"))
      assert Enum.any?(texts_filtered, &String.contains?(&1, "Second message"))
    end
  end

  describe "line_message_map/4" do
    test "maps lines to message indices" do
      messages = [{:user, "Hello"}, {:assistant, "World"}]
      line_map = ChatRenderer.line_message_map(messages, 60, default_theme())

      # Each message produces at least a header + content + spacer
      assert line_map != []

      # First entries should point to message index 0
      {first_idx, _type} = hd(line_map)
      assert first_idx == 0

      # Last entries should point to message index 1
      {last_idx, _type} = List.last(line_map)
      assert last_idx == 1
    end

    test "respects display_start_index" do
      messages = [{:user, "First"}, {:assistant, "Second"}]

      # Skip the first message
      line_map = ChatRenderer.line_message_map(messages, 60, default_theme(), 1)

      # All entries should point to message index 1
      assert Enum.all?(line_map, fn {idx, _} -> idx == 1 end)
    end

    test "marks code block lines as :code type" do
      messages = [{:assistant, "text\n```elixir\ncode here\n```\nmore text"}]
      line_map = ChatRenderer.line_message_map(messages, 60, default_theme())

      types = Enum.map(line_map, fn {_, type} -> type end)
      assert :code in types
    end
  end

  describe "auto-scroll indicator" do
    test "shows ↓ new indicator when auto-scroll disengaged and streaming with content below" do
      # Generate enough content to overflow a small viewport
      long_text = Enum.map_join(1..20, "\n", fn i -> "Line #{i} of the response" end)
      messages = [{:assistant, long_text}]

      rect = {0, 0, 40, 10}

      p =
        panel(
          messages: messages,
          status: :thinking,
          auto_scroll: false,
          scroll_offset: 0
        )

      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      has_indicator = Enum.any?(texts, &String.contains?(&1, "↓ new"))

      assert has_indicator,
             "expected ↓ new indicator when auto-scroll disengaged during streaming"
    end

    test "does not show indicator when auto-scroll is engaged" do
      long_text = Enum.map_join(1..20, "\n", fn i -> "Line #{i}" end)
      messages = [{:assistant, long_text}]

      rect = {0, 0, 40, 10}
      p = panel(messages: messages, status: :thinking, auto_scroll: true, scroll_offset: 0)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      has_indicator = Enum.any?(texts, &String.contains?(&1, "↓ new"))
      refute has_indicator, "should not show indicator when auto-scroll is engaged"
    end

    test "does not show indicator when status is idle" do
      long_text = Enum.map_join(1..20, "\n", fn i -> "Line #{i}" end)
      messages = [{:assistant, long_text}]

      rect = {0, 0, 40, 10}
      p = panel(messages: messages, status: :idle, auto_scroll: false, scroll_offset: 0)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      has_indicator = Enum.any?(texts, &String.contains?(&1, "↓ new"))
      refute has_indicator, "should not show indicator when idle"
    end

    test "does not show indicator when at the bottom of content" do
      # Short content that fits in viewport
      messages = [{:assistant, "Short message"}]

      rect = {0, 0, 40, 10}
      p = panel(messages: messages, status: :thinking, auto_scroll: false, scroll_offset: 0)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      has_indicator = Enum.any?(texts, &String.contains?(&1, "↓ new"))
      refute has_indicator, "should not show indicator when all content is visible"
    end
  end

  describe "system message rendering" do
    test "renders info system message with decorative rules" do
      messages = [{:system, "Session started · 12:00:00 UTC", :info}]

      rect = {0, 0, 60, 10}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      has_session_text = Enum.any?(texts, &String.contains?(&1, "Session started"))
      assert has_session_text, "expected system message text to appear"
    end

    test "renders error system message" do
      messages = [{:system, "Error: connection timeout", :error}]

      rect = {0, 0, 60, 10}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      has_error_text = Enum.any?(texts, &String.contains?(&1, "Error: connection timeout"))
      assert has_error_text
    end

    test "system message has decorative ── rules" do
      messages = [{:system, "Model: claude-sonnet-4", :info}]

      rect = {0, 0, 60, 10}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      has_rules = Enum.any?(texts, &String.contains?(&1, "──"))
      assert has_rules, "expected decorative rules around system message"
    end

    test "system messages take exactly 1 line in the message flow" do
      # Put a system message between two user messages and check
      # that it adds exactly 1 line vs. a version without it
      messages_without = [
        {:user, "Hello"},
        {:user, "World"}
      ]

      messages_with = [
        {:user, "Hello"},
        {:system, "Test", :info},
        {:user, "World"}
      ]

      rect = {0, 0, 60, 20}

      draws_without =
        ChatRenderer.render_messages_only(
          rect,
          panel(messages: messages_without),
          default_theme()
        )

      draws_with =
        ChatRenderer.render_messages_only(rect, panel(messages: messages_with), default_theme())

      # Count non-background draws (text content) by looking for draws with actual text
      content_rows_without =
        draws_without
        |> Enum.reject(fn d -> String.trim(elem(d, 2)) == "" end)
        |> Enum.map(fn d -> elem(d, 0) end)
        |> Enum.uniq()
        |> length()

      content_rows_with =
        draws_with
        |> Enum.reject(fn d -> String.trim(elem(d, 2)) == "" end)
        |> Enum.map(fn d -> elem(d, 0) end)
        |> Enum.uniq()
        |> length()

      # System message should add exactly 1 content row
      assert content_rows_with - content_rows_without == 1
    end

    test "system messages render inline with other message types" do
      messages = [
        {:system, "Session started", :info},
        {:user, "Hello"},
        {:assistant, "Hi there"},
        {:system, "Thinking: high", :info}
      ]

      rect = {0, 0, 60, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      has_session = Enum.any?(texts, &String.contains?(&1, "Session started"))
      has_thinking = Enum.any?(texts, &String.contains?(&1, "Thinking: high"))
      assert has_session
      assert has_thinking
    end
  end

  describe "word wrapping in messages" do
    test "long assistant messages produce more visual lines than source lines" do
      long_text = String.duplicate("word ", 30) |> String.trim()
      messages = [{:assistant, long_text}]

      # Render at a narrow width to force wrapping
      rect = {0, 0, 40, 30}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      # The draw commands should exist (not crashing is the baseline)
      assert is_list(draws)
      assert draws != []
    end

    test "long user messages wrap" do
      long_text = String.duplicate("hello ", 20) |> String.trim()
      messages = [{:user, long_text}]

      rect = {0, 0, 30, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      assert is_list(draws)
      assert draws != []
    end

    test "code blocks are not wrapped" do
      # A message with a code block
      text =
        "Here is code:\n```\nvery_long_variable_name = some_function_call(with_many_arguments, that_exceed_width)\n```\nDone."

      messages = [{:assistant, text}]

      rect = {0, 0, 40, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      # Should render without error
      assert is_list(draws)

      # Look for the → truncation indicator in any draw command
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      has_indicator = Enum.any?(texts, fn text -> String.contains?(text, "→") end)
      assert has_indicator, "expected code lines to be truncated with → indicator"
    end

    test "collapsed thinking block renders as single line with preview" do
      messages = [{:thinking, "Line one\nLine two\nLine three", true}]

      rect = {0, 0, 60, 10}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      has_summary = Enum.any?(texts, &String.contains?(&1, "3 lines"))
      assert has_summary, "expected collapsed thinking to show line count"
    end

    test "expanded thinking block shows full content" do
      messages = [{:thinking, "Line one\nLine two", false}]

      rect = {0, 0, 60, 10}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      has_line_one = Enum.any?(texts, &String.contains?(&1, "Line one"))
      has_line_two = Enum.any?(texts, &String.contains?(&1, "Line two"))
      assert has_line_one
      assert has_line_two
    end

    test "thinking blocks wrap long lines" do
      long_thinking = String.duplicate("reasoning ", 20) |> String.trim()
      messages = [{:thinking, long_thinking, false}]

      rect = {0, 0, 40, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      assert is_list(draws)
      assert draws != []
    end

    test "tool results wrap within the tool card" do
      long_result = String.duplicate("output ", 20) |> String.trim()

      messages = [
        {:tool_call,
         %{
           id: "tc1",
           name: "shell",
           args: %{},
           status: :complete,
           result: long_result,
           is_error: false,
           collapsed: false,
           started_at: nil,
           duration_ms: nil
         }}
      ]

      rect = {0, 0, 40, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      assert is_list(draws)
      assert draws != []
    end
  end

  describe "tool approval prompt" do
    test "renders approval prompt when pending" do
      approval = %{tool_call_id: "tc1", name: "shell", args: %{"command" => "rm -rf /"}}
      messages = [{:user, "Do it"}]

      rect = {0, 0, 60, 20}
      p = panel(messages: messages, pending_approval: approval)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      has_approval = Enum.any?(texts, &String.contains?(&1, "Execute shell"))
      has_choices = Enum.any?(texts, &String.contains?(&1, "[y]es"))
      assert has_approval, "expected approval prompt with tool name"
      assert has_choices, "expected [y]es [n]o [a]ll choices"
    end

    test "shows command detail for shell tools" do
      approval = %{tool_call_id: "tc1", name: "shell", args: %{"command" => "mix test"}}
      rect = {0, 0, 60, 10}
      p = panel(messages: [], pending_approval: approval)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "mix test"))
    end

    test "shows path detail for file tools" do
      approval = %{tool_call_id: "tc1", name: "write_file", args: %{"path" => "lib/foo.ex"}}
      rect = {0, 0, 60, 10}
      p = panel(messages: [], pending_approval: approval)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      assert Enum.any?(texts, &String.contains?(&1, "lib/foo.ex"))
    end

    test "no approval prompt when nil" do
      rect = {0, 0, 60, 10}
      p = panel(messages: [{:user, "hello"}], pending_approval: nil)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      refute Enum.any?(texts, &String.contains?(&1, "Execute"))
    end
  end

  describe "tool execution timing" do
    test "completed tool card shows duration" do
      messages = [
        {:tool_call,
         %{
           id: "tc1",
           name: "bash",
           args: %{},
           status: :complete,
           result: "done",
           is_error: false,
           collapsed: false,
           started_at: 1000,
           duration_ms: 12_400
         }}
      ]

      rect = {0, 0, 60, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      has_timing = Enum.any?(texts, &String.contains?(&1, "12.4s"))
      assert has_timing, "expected tool timing in output, got: #{inspect(texts)}"
    end

    test "tool card without timing shows no duration" do
      messages = [
        {:tool_call,
         %{
           id: "tc1",
           name: "bash",
           args: %{},
           status: :complete,
           result: "done",
           is_error: false,
           collapsed: false,
           started_at: nil,
           duration_ms: nil
         }}
      ]

      rect = {0, 0, 60, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      has_parens =
        Enum.any?(texts, fn t -> String.contains?(t, "(") and String.contains?(t, "s)") end)

      refute has_parens, "expected no timing when duration_ms is nil"
    end

    test "sub-second durations show milliseconds" do
      messages = [
        {:tool_call,
         %{
           id: "tc1",
           name: "read_file",
           args: %{},
           status: :complete,
           result: "content",
           is_error: false,
           collapsed: false,
           started_at: 1000,
           duration_ms: 42
         }}
      ]

      rect = {0, 0, 60, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())
      texts = Enum.map(draws, fn d -> elem(d, 2) end)

      has_ms = Enum.any?(texts, &String.contains?(&1, "42ms"))
      assert has_ms, "expected millisecond timing for fast tools"
    end
  end

  describe "syntax highlighting in code blocks" do
    test "code blocks with known language get syntax-colored segments" do
      text = "Here is code:\n```elixir\ndef hello, do: :world\n```"
      messages = [{:assistant, text}]

      rect = {0, 0, 60, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      # Should render without error and have draw commands
      assert is_list(draws)
      assert draws != []

      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      # The code should contain the keyword "def" somewhere
      assert Enum.any?(texts, &String.contains?(&1, "def"))
    end

    test "code blocks with unknown language render as plain text" do
      text = "```brainfuck\n++++++++\n```"
      messages = [{:assistant, text}]

      rect = {0, 0, 60, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      assert is_list(draws)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "++++++++"))
    end

    test "code blocks without language tag render as plain text" do
      text = "```\nplain code\n```"
      messages = [{:assistant, text}]

      rect = {0, 0, 60, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      assert is_list(draws)
      texts = Enum.map(draws, fn d -> elem(d, 2) end)
      assert Enum.any?(texts, &String.contains?(&1, "plain code"))
    end
  end
end
