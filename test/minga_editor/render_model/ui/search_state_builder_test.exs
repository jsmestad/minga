defmodule MingaEditor.RenderModel.UI.SearchStateBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.SearchStateBuilder
  alias Minga.RenderModel.UI.SearchState
  alias MingaEditor.State.Search

  describe "build/2" do
    test "returns inactive model when gui_search is nil" do
      search = %Search{}
      model = SearchStateBuilder.build(search, nil)

      assert %SearchState{} = model
      assert model.active == false
    end

    test "returns active model when gui_search is present" do
      search = %Search{
        gui_search: %{
          case_sensitive: true,
          whole_word: false,
          regex: false,
          replace_mode: false
        },
        last_pattern: nil
      }

      model = SearchStateBuilder.build(search, nil)

      assert %SearchState{} = model
      assert model.active == true
      assert model.match_count == 0
      assert model.current_index == 0
      assert model.case_sensitive == true
      assert model.whole_word == false
      assert model.regex == false
      assert model.replace_mode == false
    end

    test "preserves search flags" do
      search = %Search{
        gui_search: %{
          case_sensitive: false,
          whole_word: true,
          regex: true,
          replace_mode: true
        },
        last_pattern: nil
      }

      model = SearchStateBuilder.build(search, nil)

      assert model.case_sensitive == false
      assert model.whole_word == true
      assert model.regex == true
      assert model.replace_mode == true
    end
  end
end
