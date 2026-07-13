defmodule MingaEditor.Input.HoverTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State, as: EditorState
  alias MingaEditor.HoverPopup
  alias MingaEditor.Input.Hover

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
      assert EditorState.hover_popup(new_state).focused == true
    end

    test "any other key dismisses hover and passes through" do
      state = state_with_hover()
      assert {:passthrough, new_state} = Hover.handle_key(state, @key_h, @none)
      assert EditorState.hover_popup(new_state) == nil
    end
  end

  describe "handle_key/3 with focused hover" do
    test "j scrolls down" do
      state = state_with_hover(focused: true)
      assert {:handled, new_state} = Hover.handle_key(state, @key_j, @none)
      assert EditorState.hover_popup(new_state).scroll_offset > 0
    end

    test "k scrolls up" do
      state = state_with_hover(focused: true)
      # Scroll down first so we can scroll up
      state =
        MingaEditor.Shell.Traditional.HoverPopupWorkflow.show(
          state,
          HoverPopup.scroll_down(EditorState.hover_popup(state))
        )

      assert {:handled, new_state} = Hover.handle_key(state, @key_k, @none)
      assert EditorState.hover_popup(new_state).scroll_offset == 0
    end

    test "q dismisses" do
      state = state_with_hover(focused: true)
      assert {:handled, new_state} = Hover.handle_key(state, @key_q, @none)
      assert EditorState.hover_popup(new_state) == nil
    end

    test "Escape dismisses" do
      state = state_with_hover(focused: true)
      assert {:handled, new_state} = Hover.handle_key(state, @key_escape, @none)
      assert EditorState.hover_popup(new_state) == nil
    end

    test "other keys dismiss and pass through" do
      state = state_with_hover(focused: true)
      assert {:passthrough, new_state} = Hover.handle_key(state, @key_h, @none)
      assert EditorState.hover_popup(new_state) == nil
    end
  end

  describe "handle_mouse/7 sticky behavior (#2629)" do
    test "motion event reaching the hover handler keeps the popup open" do
      state = state_with_hover()
      # The hover node only receives motion when the pointer is inside the popup
      # rect, so this handler keeps the popup for any motion that reaches it; the
      # coordinate-gated routing is tested in MingaEditor.MouseTest.
      assert {:handled, new_state} = Hover.handle_mouse(state, 0, 0, :none, @none, :motion, 1)
      assert %HoverPopup{} = EditorState.hover_popup(new_state)
    end

    test "wheel scrolls the popup even when not focused" do
      state = state_with_hover()

      assert {:handled, new_state} =
               Hover.handle_mouse(state, 0, 0, :wheel_down, @none, :press, 1)

      assert EditorState.hover_popup(new_state).scroll_offset > 0
    end

    test "clicking inside the popup focuses it instead of dismissing" do
      state = state_with_hover()
      assert {:handled, new_state} = Hover.handle_mouse(state, 0, 0, :left, @none, :press, 1)
      assert %HoverPopup{focused: true} = EditorState.hover_popup(new_state)
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
      popup = EditorState.hover_popup(new_state)
      assert popup != nil
      assert popup.expanded?
    end

    test "o dismisses a non-expandable popup (no special behavior)" do
      state = state_with_hover(focused: true)
      assert {:passthrough, new_state} = Hover.handle_key(state, @key_o, @none)
      assert EditorState.hover_popup(new_state) == nil
    end
  end
end
