defmodule Minga.Input.HoverTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.HoverPopup
  alias Minga.Input.Hover

  import Minga.Editor.RenderPipeline.TestHelpers

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

    Minga.Editor.State.set_hover_popup(state, popup)
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
      assert new_state.shell_state.hover_popup.focused == true
    end

    test "any other key dismisses hover and passes through" do
      state = state_with_hover()
      assert {:passthrough, new_state} = Hover.handle_key(state, @key_h, @none)
      assert new_state.shell_state.hover_popup == nil
    end
  end

  describe "handle_key/3 with focused hover" do
    test "j scrolls down" do
      state = state_with_hover(focused: true)
      assert {:handled, new_state} = Hover.handle_key(state, @key_j, @none)
      assert new_state.shell_state.hover_popup.scroll_offset > 0
    end

    test "k scrolls up" do
      state = state_with_hover(focused: true)
      # Scroll down first so we can scroll up
      state =
        Minga.Editor.State.set_hover_popup(
          state,
          HoverPopup.scroll_down(state.shell_state.hover_popup)
        )

      assert {:handled, new_state} = Hover.handle_key(state, @key_k, @none)
      assert new_state.shell_state.hover_popup.scroll_offset == 0
    end

    test "q dismisses" do
      state = state_with_hover(focused: true)
      assert {:handled, new_state} = Hover.handle_key(state, @key_q, @none)
      assert new_state.shell_state.hover_popup == nil
    end

    test "Escape dismisses" do
      state = state_with_hover(focused: true)
      assert {:handled, new_state} = Hover.handle_key(state, @key_escape, @none)
      assert new_state.shell_state.hover_popup == nil
    end

    test "other keys dismiss and pass through" do
      state = state_with_hover(focused: true)
      assert {:passthrough, new_state} = Hover.handle_key(state, @key_h, @none)
      assert new_state.shell_state.hover_popup == nil
    end
  end
end
