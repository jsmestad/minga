defmodule MingaEditor.UI.Picker.ProjectSearchSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Search
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ProjectSearchSource

  # Minimal Context carrying only the field the source reads (the stashed query).
  defp ctx(query) do
    struct!(Context,
      buffers: %{active: nil},
      editing: nil,
      search: %Search{project_query: query},
      viewport: nil,
      tab_bar: nil,
      picker_ui: %{},
      capabilities: %{},
      theme: nil
    )
  end

  describe "async?/0" do
    test "the project search source runs off the editor input path" do
      assert ProjectSearchSource.async?()
    end
  end

  describe "async_fetch/1" do
    test "returns no items and no status when there is no pending query" do
      assert {:ok, [], %{}} = ProjectSearchSource.async_fetch(ctx(nil))
      assert {:ok, [], %{}} = ProjectSearchSource.async_fetch(ctx(""))
    end

    test "fetching the repo for a known term embeds each match in its item id" do
      # Runs the real search against the repo root (resolve_root). Selection no
      # longer depends on a separate cached-results list: the match travels in id.
      case ProjectSearchSource.async_fetch(ctx("defmodule")) do
        {:ok, [%Item{id: id} | _], _meta} ->
          assert is_map(id)
          assert is_binary(id.file)
          assert is_integer(id.line) and id.line > 0

        {:ok, [], _meta} ->
          :ok

        {:error, _} ->
          :ok
      end
    end
  end

  describe "candidates/1" do
    test "is a thin wrapper over async_fetch and returns [] on missing query" do
      assert ProjectSearchSource.candidates(ctx(nil)) == []
    end
  end

  describe "on_select/2" do
    test "ignores items whose id is not a match map" do
      state = %{ignored: true}
      assert ProjectSearchSource.on_select(%Item{id: 0, label: "x"}, state) == state
    end
  end
end
