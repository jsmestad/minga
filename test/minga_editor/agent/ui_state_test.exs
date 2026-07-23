defmodule MingaEditor.Agent.UIStateTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.Config, as: AgentConfig
  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.TranscriptProjection

  defp ui_with_input(lines, cursor \\ {0, 0}) do
    ui = UIState.new() |> MingaEditor.Agent.PromptBuffer.ensure()
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
    test "starts hidden, unfocused, empty, and uses the credential-aware default model" do
      ui = UIState.new()

      refute ui.panel.visible
      refute ui.panel.input_focused
      assert ui.panel.prompt_history == []
      assert ui.panel.history_index == -1
      assert MingaEditor.Agent.PromptBuffer.input_text(ui) == ""
      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == [""]
      assert MingaEditor.Agent.PromptBuffer.input_cursor(ui) == {0, 0}
      assert MingaEditor.Agent.PromptBuffer.input_line_count(ui) == 1
      assert MingaEditor.Agent.PromptBuffer.input_empty?(ui)
      assert ui.panel.model_name == AgentConfig.default_model()
      assert ui.panel.credentials_configured == false
    end

    test "toggle flips panel visibility" do
      assert UIState.toggle(UIState.new()).panel.visible
      refute UIState.new() |> UIState.toggle() |> UIState.toggle() |> then(& &1.panel.visible)
    end
  end

  describe "prompt editing" do
    test "inserts characters, newlines, and deletes across line boundaries" do
      ui = ui_with_input([""])

      ui =
        ui
        |> MingaEditor.Agent.PromptBuffer.insert_char("h")
        |> MingaEditor.Agent.PromptBuffer.insert_char("i")

      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == ["hi"]

      BufferProcess.move_to(ui.panel.prompt_buffer, {0, 1})
      ui = MingaEditor.Agent.PromptBuffer.insert_newline(ui)
      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == ["h", "i"]

      ui = ui_with_input(["ab", "cd"], {1, 0}) |> MingaEditor.Agent.PromptBuffer.delete_char()
      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == ["abcd"]

      ui = ui_with_input(["hi"], {0, 0}) |> MingaEditor.Agent.PromptBuffer.delete_char()
      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == ["hi"]
    end

    test "edit operations reset history index" do
      for operation <- [
            &MingaEditor.Agent.PromptBuffer.insert_char(&1, "x"),
            &MingaEditor.Agent.PromptBuffer.insert_newline/1,
            &MingaEditor.Agent.PromptBuffer.delete_char/1
          ] do
        ui =
          ui_with_input(["abc"], {0, 1})
          |> put_in([Access.key(:panel), Access.key(:history_index)], 2)

        assert operation.(ui).panel.history_index == -1
      end
    end

    test "cursor movement reports boundaries and moves within multiline input" do
      assert MingaEditor.Agent.PromptBuffer.move_cursor_up(ui_with_input(["hello"], {0, 0})) ==
               :at_top

      assert MingaEditor.Agent.PromptBuffer.move_cursor_down(ui_with_input(["hello"], {0, 0})) ==
               :at_bottom

      refute MingaEditor.Agent.PromptBuffer.move_cursor_up(ui_with_input(["ab", "cd"], {1, 0})) ==
               :at_top

      refute MingaEditor.Agent.PromptBuffer.move_cursor_down(ui_with_input(["ab", "cd"], {0, 0})) ==
               :at_bottom
    end

    test "focus starts the prompt buffer and unfocus preserves content" do
      ui = UIState.new() |> MingaEditor.Agent.PromptBuffer.set_input_focused(true)
      assert ui.panel.input_focused
      assert is_pid(ui.panel.prompt_buffer)

      ui =
        ui_with_input(["hello"])
        |> MingaEditor.Agent.PromptBuffer.set_input_focused(true)
        |> MingaEditor.Agent.PromptBuffer.set_input_focused(false)

      refute ui.panel.input_focused
      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == ["hello"]
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
        |> MingaEditor.Agent.PromptBuffer.clear_input()

      assert MingaEditor.Agent.PromptBuffer.input_lines(ui) == [""]
      assert MingaEditor.Agent.PromptBuffer.input_text(ui) == ""
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

      assert MingaEditor.Agent.PromptBuffer.input_text(ui) == "before\n#{placeholder}\nafter"

      assert MingaEditor.Agent.PromptBuffer.prompt_text(ui) ==
               "before\nline1\nline2\nline3\nafter"
    end

    test "history navigation walks older and newer prompts with clamping" do
      ui = ui_with_input([""]) |> put_history(["first", "second"])

      first = MingaEditor.Agent.PromptBuffer.history_prev(ui)
      assert MingaEditor.Agent.PromptBuffer.input_text(first) == "first"
      assert first.panel.history_index == 0

      second = MingaEditor.Agent.PromptBuffer.history_prev(first)
      assert MingaEditor.Agent.PromptBuffer.input_text(second) == "second"
      assert second.panel.history_index == 1

      assert MingaEditor.Agent.PromptBuffer.history_prev(second).panel.history_index == 1

      newer = MingaEditor.Agent.PromptBuffer.history_next(second)
      assert MingaEditor.Agent.PromptBuffer.input_text(newer) == "first"
      assert newer.panel.history_index == 0

      current = MingaEditor.Agent.PromptBuffer.history_next(newer)
      assert MingaEditor.Agent.PromptBuffer.input_text(current) == ""
      assert current.panel.history_index == -1
    end

    test "save_to_history skips blank input" do
      for text <- ["", "   "] do
        assert text
               |> List.wrap()
               |> ui_with_input()
               |> MingaEditor.Agent.PromptBuffer.save_to_history()
               |> then(& &1.panel.prompt_history) == []
      end

      assert ui_with_input(["hello"])
             |> MingaEditor.Agent.PromptBuffer.save_to_history()
             |> then(& &1.panel.prompt_history) == ["hello"]
    end
  end

  describe "paste handling" do
    test "insert_paste handles empty, direct, collapsed, sanitized, and multiple pastes" do
      ui = ui_with_input([""])
      assert MingaEditor.Agent.PromptBuffer.insert_paste(ui, "") == ui

      assert ui_with_input([""])
             |> MingaEditor.Agent.PromptBuffer.insert_paste("hello")
             |> MingaEditor.Agent.PromptBuffer.input_text() ==
               "hello"

      assert ui_with_input([""])
             |> MingaEditor.Agent.PromptBuffer.insert_paste("line1\nline2")
             |> MingaEditor.Agent.PromptBuffer.input_text() ==
               "line1\nline2"

      assert ui_with_input([""])
             |> MingaEditor.Agent.PromptBuffer.insert_paste("hello" <> <<0>> <> "world")
             |> MingaEditor.Agent.PromptBuffer.input_text() ==
               "helloworld"

      collapsed = ui_with_input([""]) |> MingaEditor.Agent.PromptBuffer.insert_paste("a\nb\nc")
      assert Enum.count(collapsed.panel.pasted_blocks) == 1
      assert hd(collapsed.panel.pasted_blocks).text == "a\nb\nc"
      assert MingaEditor.Agent.PromptBuffer.prompt_text(collapsed) == "a\nb\nc"

      multi = collapsed |> MingaEditor.Agent.PromptBuffer.insert_paste("d\ne\nf")
      assert Enum.count(multi.panel.pasted_blocks) == 2
    end

    test "toggle_paste_expand expands, collapses, and no-ops outside paste blocks" do
      ui =
        ui_with_input([""])
        |> MingaEditor.Agent.PromptBuffer.insert_paste("line1\nline2\nline3")
        |> move_to_placeholder()

      expanded = MingaEditor.Agent.PromptBuffer.toggle_paste_expand(ui)
      assert hd(expanded.panel.pasted_blocks).expanded
      assert MingaEditor.Agent.PromptBuffer.input_line_count(expanded) >= 3

      collapsed =
        expanded
        |> move_cursor_to_placeholder_line()
        |> MingaEditor.Agent.PromptBuffer.toggle_paste_expand()

      refute hd(collapsed.panel.pasted_blocks).expanded

      plain = ui_with_input(["hello"])

      assert MingaEditor.Agent.PromptBuffer.toggle_paste_expand(plain)
             |> MingaEditor.Agent.PromptBuffer.input_lines() ==
               MingaEditor.Agent.PromptBuffer.input_lines(plain)
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
      assert cleared.panel.transcript.display_start == 5
      assert cleared.panel.scroll.offset == 0
    end
  end

  describe "prompt buffer lifecycle" do
    test "ensure_prompt_buffer starts, reuses, and restarts the prompt buffer" do
      ui = UIState.new() |> MingaEditor.Agent.PromptBuffer.ensure()
      first_pid = ui.panel.prompt_buffer
      assert is_pid(first_pid)

      assert MingaEditor.Agent.PromptBuffer.ensure(ui).panel.prompt_buffer == first_pid

      ref = Process.monitor(first_pid)
      GenServer.stop(first_pid)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}

      restarted = MingaEditor.Agent.PromptBuffer.ensure(ui)
      assert is_pid(restarted.panel.prompt_buffer)
      refute restarted.panel.prompt_buffer == first_pid
    end
  end

  describe "TranscriptProjection" do
    test "cache_display installs correlated fields atomically" do
      old = TranscriptProjection.new()
      display = Transcript.display([{:assistant, "answer"}])
      styled = [%{styled_lines: [[{"answer", 1, 0, 0}]], markdown_blocks: []}]
      jump = MingaEditor.Agent.ProvenanceJump.request(1)

      projection =
        TranscriptProjection.cache_display(old, display, styled,
          display_start: 2,
          provenance_jump: jump,
          styled_fingerprint: 123
        )

      assert old == TranscriptProjection.new()
      assert projection.line_index == display.line_index
      assert projection.messages == display.display_messages
      assert projection.message_pairs == display.display_message_pairs
      assert projection.styled == styled
      assert projection.styled_fingerprint == 123
      assert projection.display_start == 2
      assert projection.provenance_jump == jump
    end

    test "cache_display without a fingerprint invalidates previous styled cache" do
      display = Transcript.display([{:assistant, "answer"}])

      projection =
        TranscriptProjection.new()
        |> TranscriptProjection.cache_display(display, [:styled], styled_fingerprint: 1)
        |> TranscriptProjection.cache_display(display, [:restyled])

      assert projection.styled_fingerprint == nil
      assert TranscriptProjection.styled_for(projection, 1) == :stale
    end

    test "clear resets projection cache and preserves version" do
      projection =
        TranscriptProjection.new()
        |> TranscriptProjection.bump_version()
        |> TranscriptProjection.cache_display(Transcript.display([{:assistant, "answer"}]), [nil],
          display_start: 1,
          provenance_jump: MingaEditor.Agent.ProvenanceJump.request(1),
          styled_fingerprint: 123
        )
        |> TranscriptProjection.clear()

      assert projection.line_index == []
      assert projection.messages == []
      assert projection.message_pairs == []
      assert projection.styled == nil
      assert projection.styled_fingerprint == nil
      assert projection.display_start == 0
      assert projection.provenance_jump == nil
      assert projection.version == 1
    end

    test "Panel.bump_message_version increments the projection counter each call" do
      panel = Panel.new()
      assert panel.transcript.version == 0

      assert panel
             |> Panel.bump_message_version()
             |> Panel.bump_message_version()
             |> then(& &1.transcript.version) == 2
    end
  end

  defp move_to_placeholder(ui) do
    line =
      Enum.find_index(
        MingaEditor.Agent.PromptBuffer.input_lines(ui),
        &UIState.paste_placeholder?/1
      )

    BufferProcess.move_to(ui.panel.prompt_buffer, {line, 0})
    ui
  end

  defp move_cursor_to_placeholder_line(ui) do
    line =
      MingaEditor.Agent.PromptBuffer.input_lines(ui)
      |> Enum.find_index(&(String.contains?(&1, "line1") or UIState.paste_placeholder?(&1)))

    BufferProcess.move_to(ui.panel.prompt_buffer, {line || 0, 0})
    ui
  end
end
