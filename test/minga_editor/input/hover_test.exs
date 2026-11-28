defmodule MingaEditor.Input.HoverTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Editing
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.HoverPopup
  alias MingaEditor.HoverPopup.Presenter
  alias MingaEditor.HoverPopup.Terminal
  alias MingaEditor.Input.Hover
  alias MingaEditor.RenderModel.UI.HoverPopupBuilder
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.HoverPopupWorkflow
  alias MingaEditor.State.Registers

  import MingaEditor.RenderPipeline.TestHelpers

  # Key constants (character literals, matching how the frontend sends them)
  @key_j ?j
  @key_k ?k
  @key_upper_k ?K
  @key_q ?q
  @key_escape 27
  @key_h ?h
  @none 0

  defp state_with_hover(opts \\ []) do
    state = base_state()
    lines = Enum.map_join(1..20, "\n", &"Documentation line #{&1}")
    popup = HoverPopup.new(lines, 10, 20)

    popup =
      if Keyword.get(opts, :focused, false),
        do: HoverPopup.focus(popup),
        else: popup

    MingaEditor.Shell.Traditional.HoverPopupWorkflow.show(state, popup)
  end

  describe "handle_key/3 with no hover popup" do
    test "passes through when no hover popup" do
      state = base_state()
      assert {:passthrough, ^state} = Hover.handle_key(state, @key_h, @none)
    end
  end

  describe "handle_key/3 with unfocused hover" do
    test "K focuses into the hover" do
      state = state_with_hover()
      assert {:handled, new_state} = Hover.handle_key(state, @key_upper_k, @none)
      assert Runtime.state(new_state.shell_runtime).hover_popup.focused == true
    end

    test "any other key dismisses hover and passes through" do
      state = state_with_hover()
      assert {:passthrough, new_state} = Hover.handle_key(state, @key_h, @none)
      assert Runtime.state(new_state.shell_runtime).hover_popup == nil
    end
  end

  describe "handle_key/3 with focused hover" do
    test "j scrolls down" do
      state = state_with_hover(focused: true)
      assert {:handled, new_state} = Hover.handle_key(state, @key_j, @none)
      assert Runtime.state(new_state.shell_runtime).hover_popup.scroll_offset > 0
    end

    test "k scrolls up" do
      state = state_with_hover(focused: true)
      # Scroll down first so we can scroll up
      state =
        MingaEditor.Shell.Traditional.HoverPopupWorkflow.show(
          state,
          HoverPopup.scroll_down(Runtime.state(state.shell_runtime).hover_popup)
        )

      assert {:handled, new_state} = Hover.handle_key(state, @key_k, @none)
      assert Runtime.state(new_state.shell_runtime).hover_popup.scroll_offset == 0
    end

    test "Ctrl-D and Ctrl-U scroll the focused popup without moving the editor cursor" do
      state = state_with_hover(focused: true)
      buffer = state.workspace.buffers.active
      cursor = Minga.Buffer.cursor(buffer)

      assert {:handled, scrolled} = Hover.handle_key(state, ?d, 0x02)
      assert Runtime.state(scrolled.shell_runtime).hover_popup.scroll_offset > 0
      assert {:handled, returned} = Hover.handle_key(scrolled, ?u, 0x02)
      assert Runtime.state(returned.shell_runtime).hover_popup.scroll_offset == 0
      assert Minga.Buffer.cursor(buffer) == cursor
    end

    test "terminal scrolling reaches the end of one long paragraph and Tab reveals its wrapped link" do
      state = base_state(rows: 24, cols: 28, rendering: :disabled)
      Minga.Buffer.set_option(state.workspace.buffers.active, :clipboard, :none)
      lead = Enum.map_join(1..33, " ", &"part#{&1}") <> " "
      label = "the very long documentation link with 日本語 and several words"
      url = "https://example.com/docs"
      tail = Enum.map_join(34..76, " ", &" part#{&1}") <> " finalword"
      document = [{[{lead, :plain}, {label, {:link, url}}, {tail, :bold}], :text}]

      popup =
        document
        |> HoverPopup.from_parsed_lines(5, 2)
        |> HoverPopup.bind_code(%{
          trigger: :pointer,
          tab: nil,
          window: 1,
          viewport: state.frontend.terminal_viewport,
          buffer: state.workspace.buffers.active,
          version: 0,
          position: {0, 0},
          anchor: {5, 2},
          terminal_caret_row: 20,
          path: nil
        })
        |> HoverPopup.resolve_code(document)

      model = fn state ->
        state |> Context.from_editor_state() |> HoverPopupBuilder.build()
      end

      visible_text = fn state ->
        Enum.map_join(model.(state).content_lines, fn line ->
          Enum.map_join(line.segments, & &1.text)
        end)
      end

      state = HoverPopupWorkflow.show(state, popup)
      assert {:handled, focused} = Hover.handle_key(state, @key_upper_k, @none)
      assert visible_text.(focused) =~ "part1 part2"
      refute visible_text.(focused) =~ "finalword"

      scrolled =
        Enum.reduce(1..12, focused, fn _, state ->
          assert {:handled, next} = Hover.handle_key(state, @key_j, @none)
          next
        end)

      assert visible_text.(scrolled) =~ "finalword"
      assert {:handled, copied} = Hover.handle_key(scrolled, ?y, @none)
      assert Registers.get(Editing.registers(copied), "") == {lead <> label <> tail, :charwise}

      assert {:handled, selected} = Hover.handle_key(scrolled, 9, @none)
      selected_popup = Runtime.state(selected.shell_runtime).hover_popup
      assert HoverPopup.link_at(selected_popup, 2) == url

      link_fragments = fn state ->
        for line <- model.(state).content_lines,
            %{style: {:link, 2, true}, text: text} <- line.segments,
            do: text
      end

      assert [_, _ | _] = link_fragments.(selected)
      assert Enum.join(link_fragments.(selected)) == label
      {row, _col, width, height} = Presenter.terminal_box(selected_popup, {24, 28})
      assert width == 28 and height <= 12
      refute 5 in row..(row + height - 1)
      refute 20 in row..(row + height - 1)

      assert {:noreply, resized} =
               MingaEditor.handle_info({:minga_input, {:resize, 44, 24}}, selected)

      refute model.(resized).visible?

      fresh_text = "New topic: " <> String.duplicate("fresh documentation ", 38)
      fresh = [{[{fresh_text, :plain}], :text}]
      current = Runtime.state(scrolled.shell_runtime).hover_popup
      enriched = HoverPopupWorkflow.show(scrolled, HoverPopup.resolve_code(current, fresh))
      assert String.starts_with?(visible_text.(enriched), "New topic:")
      assert model.(enriched).focused?
      assert model.(enriched).anchor_row == model.(scrolled).anchor_row
    end

    test "two-cell links move to the next row without joining graphemes across styles" do
      for {prefix, glyph} <- [{"a", "⌚"}, {"a", "❤️"}, {"a", "［"}, {"🇺", "🇸"}] do
        lines = [{[{prefix, :plain}, {glyph, {:link, "https://example.com"}}], :text}]
        terminal = Terminal.prepare(nil, lines, 6, 1)

        assert Terminal.page(terminal, {0, 0}, 4) == [
                 {[{prefix, :plain}], :text},
                 {[{glyph, {:hover_link, 2}}], :text}
               ]

        assert Terminal.scroll(terminal, {0, 0}, 3, 1) == {0, byte_size(prefix)}
      end
    end

    test "wraps a word across styles but keeps one run's grapheme together" do
      lines = [
        {[{"a b", :plain}, {"cd", :bold}], :text},
        {[{"🇺🇸", {:link, "https://example.com"}}], :text}
      ]

      terminal = Terminal.prepare(nil, lines, 8, 1)

      assert Terminal.page(terminal, {0, 0}, 5) == [
               {[{"a ", :plain}], :text},
               {[{"b", :plain}, {"cd", :bold}], :text},
               {[{"🇺🇸", {:hover_link, 2}}], :text}
             ]
    end

    test "yank copies styled documentation in full without dismissing a scrolled hover" do
      state = base_state()
      Minga.Buffer.set_option(state.workspace.buffers.active, :clipboard, :none)

      popup =
        "**First** paragraph\nSecond `code`\nThird\nFourth\nFifth\nSixth"
        |> HoverPopup.new(10, 20)
        |> HoverPopup.focus()
        |> HoverPopup.scroll_down()

      state = MingaEditor.Shell.Traditional.HoverPopupWorkflow.show(state, popup)
      assert {:handled, updated} = Hover.handle_key(state, ?y, @none)

      expected = "First paragraph\nSecond code\nThird\nFourth\nFifth\nSixth"
      assert Registers.get(Editing.registers(updated), "") == {expected, :charwise}
      assert Runtime.state(updated.shell_runtime).hover_popup == popup
    end

    test "Enter held with Control, Alt or Command neither opens nor dismisses a popup with an Open action" do
      state = state_with_hover(focused: true)

      popup =
        HoverPopup.with_open_action(
          Runtime.state(state.shell_runtime).hover_popup,
          :open_messages
        )

      state = MingaEditor.Shell.Traditional.HoverPopupWorkflow.show(state, popup)

      # Without enhanced key reporting a terminal sends Esc then Enter as Alt+Enter when both arrive together.
      for mods <- [0x02, 0x04, 0x08] do
        assert {:handled, ^state} = Hover.handle_key(state, 13, mods)
      end
    end

    test "q dismisses" do
      state = state_with_hover(focused: true)
      assert {:handled, new_state} = Hover.handle_key(state, @key_q, @none)
      assert Runtime.state(new_state.shell_runtime).hover_popup == nil
    end

    test "Escape dismisses" do
      state = state_with_hover(focused: true)
      assert {:handled, new_state} = Hover.handle_key(state, @key_escape, @none)
      assert Runtime.state(new_state.shell_runtime).hover_popup == nil
    end

    test "other keys dismiss and pass through" do
      state = state_with_hover(focused: true)
      assert {:passthrough, new_state} = Hover.handle_key(state, @key_h, @none)
      assert Runtime.state(new_state.shell_runtime).hover_popup == nil
    end
  end

  describe "handle_mouse/7 sticky behavior (#2629)" do
    test "motion event reaching the hover handler keeps the popup open" do
      state = state_with_hover()
      # The hover node only receives motion when the pointer is inside the popup
      # rect, so this handler keeps the popup for any motion that reaches it; the
      # coordinate-gated routing is tested in MingaEditor.MouseTest.
      assert {:handled, new_state} = Hover.handle_mouse(state, 0, 0, :none, @none, :motion, 1)
      assert %HoverPopup{} = Runtime.state(new_state.shell_runtime).hover_popup
    end

    test "wheel scrolls the popup even when not focused" do
      state = state_with_hover()

      assert {:handled, new_state} =
               Hover.handle_mouse(state, 0, 0, :wheel_down, @none, :press, 1)

      assert Runtime.state(new_state.shell_runtime).hover_popup.scroll_offset > 0
    end

    test "clicking inside the popup focuses it instead of dismissing" do
      state = state_with_hover()
      assert {:handled, new_state} = Hover.handle_mouse(state, 0, 0, :left, @none, :press, 1)
      assert %HoverPopup{focused: true} = Runtime.state(new_state.shell_runtime).hover_popup
    end
  end

  describe "handle_key/3 o (expand) on focused hover" do
    @key_o ?o

    defp state_with_expandable_hover do
      popup =
        "collapsed"
        |> HoverPopup.new(10, 20, expanded: "the full expanded text")
        |> HoverPopup.focus()

      MingaEditor.Shell.Traditional.HoverPopupWorkflow.show(base_state(), popup)
    end

    test "o toggles an expandable popup without dismissing it" do
      state = state_with_expandable_hover()
      assert {:handled, new_state} = Hover.handle_key(state, @key_o, @none)
      popup = Runtime.state(new_state.shell_runtime).hover_popup
      assert popup != nil
      assert popup.expanded?
    end

    test "o dismisses a non-expandable popup (no special behavior)" do
      state = state_with_hover(focused: true)
      assert {:passthrough, new_state} = Hover.handle_key(state, @key_o, @none)
      assert Runtime.state(new_state.shell_runtime).hover_popup == nil
    end
  end
end
