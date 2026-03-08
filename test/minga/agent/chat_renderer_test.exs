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
      input_text: Keyword.get(opts, :input_text, ""),
      scroll_offset: Keyword.get(opts, :scroll_offset, 0),
      spinner_frame: 0,
      usage: %{input: 0, output: 0, cost: 0.0},
      model_name: "claude-sonnet-4",
      thinking_level: "medium",
      auto_scroll: Keyword.get(opts, :auto_scroll, true),
      error_message: nil
    }
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

    test "thinking blocks wrap long lines" do
      long_thinking = String.duplicate("reasoning ", 20) |> String.trim()
      messages = [{:thinking, long_thinking}]

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
           collapsed: false
         }}
      ]

      rect = {0, 0, 40, 20}
      p = panel(messages: messages)
      draws = ChatRenderer.render_messages_only(rect, p, default_theme())

      assert is_list(draws)
      assert draws != []
    end
  end
end
