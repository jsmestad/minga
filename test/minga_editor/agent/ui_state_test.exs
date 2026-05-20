defmodule MingaEditor.Agent.UIStateTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.Config, as: AgentConfig
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel

  defp ui_with_input(lines, cursor \\ {0, 0}) do
    ui = UIState.new() |> UIState.ensure_prompt_buffer()
    BufferProcess.replace_content(ui.panel.prompt_buffer, Enum.join(lines, "\n"))
    BufferProcess.move_to(ui.panel.prompt_buffer, cursor)
    ui
  end

  defp put_history(ui, history, index \\ -1) do
    ui
    |> put_in([Access.key(:panel), Access.key(:prompt_history)], history)
    |> put_in([Access.key(:panel), Access.key(:history_index)], index)
  end

  describe "new/0 and basic state" do
    test "starts hidden, unfocused, empty, and configured with the default model" do
      ui = UIState.new()

      refute ui.panel.visible
      refute ui.panel.input_focused
      assert ui.panel.prompt_history == []
      assert ui.panel.history_index == -1
      assert UIState.input_text(ui) == ""
      assert UIState.input_lines(ui) == [""]
      assert UIState.input_cursor(ui) == {0, 0}
      assert UIState.input_line_count(ui) == 1
      assert UIState.input_empty?(ui)
      assert ui.panel.model_name == AgentConfig.default_model()
      assert String.contains?(ui.panel.model_name, ":")
    end

    test "toggle flips panel visibility" do
      assert UIState.toggle(UIState.new()).panel.visible
      refute UIState.new() |> UIState.toggle() |> UIState.toggle() |> then(& &1.panel.visible)
    end
  end

  describe "prompt editing" do
    test "inserts characters, newlines, and deletes across line boundaries" do
      ui = ui_with_input([""])
      ui = ui |> UIState.insert_char("h") |> UIState.insert_char("i")
      assert UIState.input_lines(ui) == ["hi"]

      BufferProcess.move_to(ui.panel.prompt_buffer, {0, 1})
      ui = UIState.insert_newline(ui)
      assert UIState.input_lines(ui) == ["h", "i"]

      ui = ui_with_input(["ab", "cd"], {1, 0}) |> UIState.delete_char()
      assert UIState.input_lines(ui) == ["abcd"]

      ui = ui_with_input(["hi"], {0, 0}) |> UIState.delete_char()
      assert UIState.input_lines(ui) == ["hi"]
    end

    test "edit operations reset history index" do
      for operation <- [
            &UIState.insert_char(&1, "x"),
            &UIState.insert_newline/1,
            &UIState.delete_char/1
          ] do
        ui =
          ui_with_input(["abc"], {0, 1})
          |> put_in([Access.key(:panel), Access.key(:history_index)], 2)

        assert operation.(ui).panel.history_index == -1
      end
    end

    test "cursor movement reports boundaries and moves within multiline input" do
      assert UIState.move_cursor_up(ui_with_input(["hello"], {0, 0})) == :at_top
      assert UIState.move_cursor_down(ui_with_input(["hello"], {0, 0})) == :at_bottom
      refute UIState.move_cursor_up(ui_with_input(["ab", "cd"], {1, 0})) == :at_top
      refute UIState.move_cursor_down(ui_with_input(["ab", "cd"], {0, 0})) == :at_bottom
    end

    test "focus starts the prompt buffer and unfocus preserves content" do
      ui = UIState.new() |> UIState.set_input_focused(true)
      assert ui.panel.input_focused
      assert is_pid(ui.panel.prompt_buffer)

      ui =
        ui_with_input(["hello"])
        |> UIState.set_input_focused(true)
        |> UIState.set_input_focused(false)

      refute ui.panel.input_focused
      assert UIState.input_lines(ui) == ["hello"]
    end
  end

  describe "input clearing, text access, and history" do
    test "clear_input saves non-empty prompts, resets editing state, and clears paste blocks" do
      ui =
        ui_with_input(["hello", "world"])
        |> put_in([Access.key(:panel), Access.key(:history_index)], 1)
        |> put_in([Access.key(:panel), Access.key(:pasted_blocks)], [
          %{text: "paste", expanded: false}
        ])
        |> UIState.clear_input()

      assert UIState.input_lines(ui) == [""]
      assert UIState.input_text(ui) == ""
      assert ui.panel.prompt_history == ["hello\nworld"]
      assert ui.panel.history_index == -1
      assert ui.panel.pasted_blocks == []
    end

    test "prompt_text substitutes paste placeholders while input_text stays raw" do
      placeholder = <<0>> <> "PASTE:0"

      ui =
        ui_with_input(["before", placeholder, "after"])
        |> put_in([Access.key(:panel), Access.key(:pasted_blocks)], [
          %{text: "line1\nline2\nline3", expanded: false}
        ])

      assert UIState.input_text(ui) == "before\n#{placeholder}\nafter"
      assert UIState.prompt_text(ui) == "before\nline1\nline2\nline3\nafter"
    end

    test "history navigation walks older and newer prompts with clamping" do
      ui = ui_with_input([""]) |> put_history(["first", "second"])

      first = UIState.history_prev(ui)
      assert UIState.input_text(first) == "first"
      assert first.panel.history_index == 0

      second = UIState.history_prev(first)
      assert UIState.input_text(second) == "second"
      assert second.panel.history_index == 1

      assert UIState.history_prev(second).panel.history_index == 1

      newer = UIState.history_next(second)
      assert UIState.input_text(newer) == "first"
      assert newer.panel.history_index == 0

      current = UIState.history_next(newer)
      assert UIState.input_text(current) == ""
      assert current.panel.history_index == -1
    end

    test "save_to_history skips blank input" do
      for text <- ["", "   "] do
        assert text
               |> List.wrap()
               |> ui_with_input()
               |> UIState.save_to_history()
               |> then(& &1.panel.prompt_history) == []
      end

      assert ui_with_input(["hello"])
             |> UIState.save_to_history()
             |> then(& &1.panel.prompt_history) == ["hello"]
    end
  end

  describe "paste handling" do
    test "insert_paste handles empty, direct, collapsed, sanitized, and multiple pastes" do
      ui = ui_with_input([""])
      assert UIState.insert_paste(ui, "") == ui

      assert ui_with_input([""]) |> UIState.insert_paste("hello") |> UIState.input_text() ==
               "hello"

      assert ui_with_input([""]) |> UIState.insert_paste("line1\nline2") |> UIState.input_text() ==
               "line1\nline2"

      assert ui_with_input([""])
             |> UIState.insert_paste("hello" <> <<0>> <> "world")
             |> UIState.input_text() ==
               "helloworld"

      collapsed = ui_with_input([""]) |> UIState.insert_paste("a\nb\nc")
      assert length(collapsed.panel.pasted_blocks) == 1
      assert hd(collapsed.panel.pasted_blocks).text == "a\nb\nc"
      assert UIState.prompt_text(collapsed) == "a\nb\nc"

      multi = collapsed |> UIState.insert_paste("d\ne\nf")
      assert length(multi.panel.pasted_blocks) == 2
    end

    test "toggle_paste_expand expands, collapses, and no-ops outside paste blocks" do
      ui =
        ui_with_input([""])
        |> UIState.insert_paste("line1\nline2\nline3")
        |> move_to_placeholder()

      expanded = UIState.toggle_paste_expand(ui)
      assert hd(expanded.panel.pasted_blocks).expanded
      assert UIState.input_line_count(expanded) >= 3

      collapsed = expanded |> move_cursor_to_placeholder_line() |> UIState.toggle_paste_expand()
      refute hd(collapsed.panel.pasted_blocks).expanded

      plain = ui_with_input(["hello"])

      assert UIState.toggle_paste_expand(plain) |> UIState.input_lines() ==
               UIState.input_lines(plain)
    end

    test "placeholder helpers parse only paste placeholders" do
      placeholder0 = <<0>> <> "PASTE:0"
      placeholder5 = <<0>> <> "PASTE:5"

      assert UIState.paste_placeholder?(placeholder0)
      refute UIState.paste_placeholder?("hello")
      assert UIState.paste_block_index(placeholder0) == 0
      assert UIState.paste_block_index(placeholder5) == 5
      assert UIState.paste_block_index("hello") == nil
    end
  end

  describe "scrolling and display" do
    test "scrolling updates offset and clear_display resets visible start and scroll" do
      ui = UIState.new() |> UIState.scroll_up(5)
      refute ui.panel.scroll.pinned

      ui =
        put_in(ui.panel.scroll, %{ui.panel.scroll | offset: 10, pinned: false})
        |> UIState.scroll_down(3)

      assert ui.panel.scroll.offset == 13

      cleared = ui |> UIState.scroll_up(10) |> UIState.clear_display(5)
      assert cleared.panel.display_start_index == 5
      assert cleared.panel.scroll.offset == 0
    end
  end

  describe "prompt buffer lifecycle" do
    test "ensure_prompt_buffer starts, reuses, and restarts the prompt buffer" do
      ui = UIState.new() |> UIState.ensure_prompt_buffer()
      first_pid = ui.panel.prompt_buffer
      assert is_pid(first_pid)

      assert UIState.ensure_prompt_buffer(ui).panel.prompt_buffer == first_pid

      ref = Process.monitor(first_pid)
      GenServer.stop(first_pid)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}

      restarted = UIState.ensure_prompt_buffer(ui)
      assert is_pid(restarted.panel.prompt_buffer)
      refute restarted.panel.prompt_buffer == first_pid
    end
  end

  describe "Panel.bump_message_version/1" do
    test "increments the counter each call" do
      panel = Panel.new()
      assert panel.message_version == 0

      assert panel
             |> Panel.bump_message_version()
             |> Panel.bump_message_version()
             |> then(& &1.message_version) == 2
    end
  end

  defp move_to_placeholder(ui) do
    line = Enum.find_index(UIState.input_lines(ui), &UIState.paste_placeholder?/1)
    BufferProcess.move_to(ui.panel.prompt_buffer, {line, 0})
    ui
  end

  defp move_cursor_to_placeholder_line(ui) do
    line =
      UIState.input_lines(ui)
      |> Enum.find_index(&(String.contains?(&1, "line1") or UIState.paste_placeholder?(&1)))

    BufferProcess.move_to(ui.panel.prompt_buffer, {line || 0, 0})
    ui
  end
end
