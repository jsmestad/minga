defmodule Minga.RenderModel.UI.SearchStateTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.SearchState

  describe "%SearchState{}" do
    test "defaults to inactive" do
      ss = %SearchState{active: false}

      assert ss.active == false
      assert ss.match_count == 0
      assert ss.current_index == 0
      assert ss.case_sensitive == true
      assert ss.whole_word == false
      assert ss.regex == false
      assert ss.replace_mode == false
    end

    test "accepts all fields" do
      ss = %SearchState{
        active: true,
        match_count: 42,
        current_index: 7,
        case_sensitive: false,
        whole_word: true,
        regex: true,
        replace_mode: true
      }

      assert ss.active == true
      assert ss.match_count == 42
      assert ss.current_index == 7
      assert ss.case_sensitive == false
      assert ss.whole_word == true
      assert ss.regex == true
      assert ss.replace_mode == true
    end

    test "requires active" do
      assert_raise ArgumentError, fn ->
        struct!(SearchState, %{})
      end
    end
  end
end
