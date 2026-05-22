defmodule Minga.Keymap.Scope.GitStatusScopeTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Scope

  @enter 13
  @escape 27
  @tab 9

  describe "normal mode bindings" do
    test "one-key git actions resolve to their expected commands" do
      assert_expected_commands([
        {{?s, 0}, :git_status_stage},
        {{?u, 0}, :git_status_unstage},
        {{?d, 0}, :git_status_discard},
        {{?S, 0}, :git_status_stage_all},
        {{?U, 0}, :git_status_unstage_all},
        {{?p, 0}, :git_status_open_diff},
        {{?P, 0}, :git_status_push},
        {{?l, 0}, :git_status_pull},
        {{?f, 0}, :git_status_fetch},
        {{?y, 0}, :git_status_confirm_discard},
        {{?n, 0}, :git_status_cancel_discard}
      ])
    end

    test "Tab toggles section collapse" do
      assert {:command, :git_status_toggle_section} =
               Scope.resolve_key(:git_status, :normal, {@tab, 0})
    end

    test "Enter opens the selected file" do
      assert {:command, :git_status_open_file} =
               Scope.resolve_key(:git_status, :normal, {@enter, 0})
    end

    test "q closes the panel" do
      assert {:command, :git_status_close} = Scope.resolve_key(:git_status, :normal, {?q, 0})
    end

    test "Escape closes the panel" do
      assert {:command, :git_status_close} = Scope.resolve_key(:git_status, :normal, {@escape, 0})
    end

    test "cc starts a commit" do
      {:prefix, c_node} = Scope.resolve_key(:git_status, :normal, {?c, 0})
      assert {:command, :git_status_start_commit} = Scope.resolve_key_in_node(c_node, {?c, 0})
    end

    test "ca amends the last commit" do
      {:prefix, c_node} = Scope.resolve_key(:git_status, :normal, {?c, 0})
      assert {:command, :git_status_amend} = Scope.resolve_key_in_node(c_node, {?a, 0})
    end

    test "cg generates a commit message" do
      {:prefix, c_node} = Scope.resolve_key(:git_status, :normal, {?c, 0})
      assert {:command, :git_generate_commit_message} = Scope.resolve_key_in_node(c_node, {?g, 0})
    end

    defp assert_expected_commands(pairs) do
      Enum.each(pairs, fn {key, expected_command} ->
        assert {:command, ^expected_command} = Scope.resolve_key(:git_status, :normal, key)
      end)
    end
  end
end
