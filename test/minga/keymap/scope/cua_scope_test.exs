defmodule Minga.Keymap.Scope.CUAScopeTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Scope

  # Arrow keys (Kitty protocol)
  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_left 57_350
  @arrow_right 57_351

  @enter 13
  @escape 27
  @cmd 0x08

  describe "file_tree scope with :cua" do
    test "arrow up/down resolve to movement commands" do
      assert {:command, :move_up} = Scope.resolve_key(:file_tree, :cua, {@arrow_up, 0})
      assert {:command, :move_down} = Scope.resolve_key(:file_tree, :cua, {@arrow_down, 0})
    end

    test "arrow right expands directory" do
      assert {:command, :tree_expand} = Scope.resolve_key(:file_tree, :cua, {@arrow_right, 0})
    end

    test "arrow left collapses directory" do
      assert {:command, :tree_collapse} = Scope.resolve_key(:file_tree, :cua, {@arrow_left, 0})
    end

    test "Enter opens file" do
      assert {:command, :tree_open_or_toggle} = Scope.resolve_key(:file_tree, :cua, {@enter, 0})
    end

    test "Escape closes tree" do
      assert {:command, :tree_close} = Scope.resolve_key(:file_tree, :cua, {@escape, 0})
    end

    test "vim j/k are not bound in CUA mode" do
      assert :not_found = Scope.resolve_key(:file_tree, :cua, {?j, 0})
      assert :not_found = Scope.resolve_key(:file_tree, :cua, {?k, 0})
    end
  end

  describe "agent scope with :cua" do
    test "arrow up/down resolve to agent-specific navigation" do
      assert {:command, :agent_input_up} = Scope.resolve_key(:agent, :cua, {@arrow_up, 0})
      assert {:command, :agent_input_down} = Scope.resolve_key(:agent, :cua, {@arrow_down, 0})
    end

    test "Enter focuses input" do
      assert {:command, :agent_focus_input} = Scope.resolve_key(:agent, :cua, {@enter, 0})
    end

    test "Cmd+C copies code block" do
      assert {:command, :agent_copy_code_block} = Scope.resolve_key(:agent, :cua, {?c, @cmd})
    end

    test "Escape dismisses" do
      assert {:command, :agent_dismiss_or_noop} = Scope.resolve_key(:agent, :cua, {@escape, 0})
    end
  end

  describe "git_status scope with :cua" do
    test "arrow up/down navigate entries" do
      assert {:command, :move_up} = Scope.resolve_key(:git_status, :cua, {@arrow_up, 0})
      assert {:command, :move_down} = Scope.resolve_key(:git_status, :cua, {@arrow_down, 0})
    end

    test "Enter opens file" do
      assert {:command, :git_status_open_file} = Scope.resolve_key(:git_status, :cua, {@enter, 0})
    end

    test "Escape closes panel" do
      assert {:command, :git_status_close} = Scope.resolve_key(:git_status, :cua, {@escape, 0})
    end

    test "s stages file (domain key shared with vim)" do
      assert {:command, :git_status_stage} = Scope.resolve_key(:git_status, :cua, {?s, 0})
    end
  end

  describe "editor scope with :cua" do
    test "returns :not_found (CUA.Dispatch handles buffer editing)" do
      assert :not_found = Scope.resolve_key(:editor, :cua, {?a, 0})
    end
  end
end
