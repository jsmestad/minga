defmodule MingaEditor.RenderModel.UI.SearchStateBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.SearchStateBuilder
  alias Minga.RenderModel.UI.SearchState
  alias MingaEditor.State.Search.Projection

  describe "build/1" do
    test "projects the bounded search snapshot without buffer access" do
      search = projection(active: false)
      model = SearchStateBuilder.build(search)

      assert %SearchState{} = model
      assert model.active == false
    end

    test "returns active model when gui_search is present" do
      search =
        projection(
          active: true,
          query: "café",
          session_id: 4,
          acknowledged_edit_seq: 2,
          case_sensitive: true,
          match_count: 70_000,
          current_index: 65_536,
          status: :rebuilding
        )

      model = SearchStateBuilder.build(search)

      assert %SearchState{} = model
      assert model.active == true
      assert model.query == "café"
      assert model.session_id == 4
      assert model.acknowledged_edit_seq == 2
      assert model.match_count == 70_000
      assert model.current_index == 65_536
      assert model.case_sensitive == true
      assert model.whole_word == false
      assert model.regex == false
      assert model.replace_mode == false
      assert model.status == :rebuilding
    end

    test "preserves an inactive authoritative session and clears stale counters" do
      search =
        projection(
          active: false,
          query: "foo",
          session_id: 9,
          acknowledged_edit_seq: 7,
          whole_word: true,
          regex: true,
          replace_mode: true,
          status: :failed
        )

      model = SearchStateBuilder.build(search)

      assert model.active == false
      assert model.query == "foo"
      assert model.session_id == 9
      assert model.acknowledged_edit_seq == 7
      assert model.match_count == 0
      assert model.current_index == 0
      assert model.case_sensitive == false
      assert model.whole_word == true
      assert model.regex == true
      assert model.replace_mode == true
      assert model.status == :failed
    end
  end

  defp projection(overrides) do
    defaults = %{
      active: false,
      query: "",
      session_id: 0,
      acknowledged_edit_seq: 0,
      match_count: 0,
      current_index: 0,
      case_sensitive: false,
      whole_word: false,
      regex: false,
      replace_mode: false,
      status: :ready
    }

    struct!(Projection, Map.merge(defaults, Map.new(overrides)))
  end
end
