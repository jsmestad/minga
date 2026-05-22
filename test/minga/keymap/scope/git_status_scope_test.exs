defmodule Minga.Keymap.Scope.GitStatusScopeTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Scope

  describe "normal mode bindings" do
    test "single-key git actions resolve" do
      assert {:command, :git_status_stage} = Scope.resolve_key(:git_status, :normal, {?s, 0})
      assert {:command, :git_status_unstage} = Scope.resolve_key(:git_status, :normal, {?u, 0})
      assert {:command, :git_status_discard} = Scope.resolve_key(:git_status, :normal, {?d, 0})
      assert {:command, :git_status_open_diff} = Scope.resolve_key(:git_status, :normal, {?p, 0})
      assert {:command, :git_status_push} = Scope.resolve_key(:git_status, :normal, {?P, 0})
      assert {:command, :git_status_pull} = Scope.resolve_key(:git_status, :normal, {?l, 0})
      assert {:command, :git_status_fetch} = Scope.resolve_key(:git_status, :normal, {?f, 0})
    end

    test "enter, q, and escape close or open the panel" do
      assert {:command, :git_status_open_file} = Scope.resolve_key(:git_status, :normal, {13, 0})
      assert {:command, :git_status_close} = Scope.resolve_key(:git_status, :normal, {?q, 0})
      assert {:command, :git_status_close} = Scope.resolve_key(:git_status, :normal, {27, 0})
    end

    test "commit prefixes resolve to the expected commands" do
      assert {:prefix, node} = Scope.resolve_key(:git_status, :normal, {?c, 0})
      assert {:command, :git_status_start_commit} = Scope.resolve_key_in_node(node, {?c, 0})
      assert {:command, :git_status_amend} = Scope.resolve_key_in_node(node, {?a, 0})
      assert {:command, :git_generate_commit_message} = Scope.resolve_key_in_node(node, {?g, 0})
    end
  end
end
