defmodule MingaEditor.UI.Picker.PickerNextStepsSourcesTest do
  @moduledoc """
  What each picker source says and offers when nothing matches: project search, the switcher and file finder, diagnostics and the extension list.
  """

  use ExUnit.Case, async: true

  alias Minga.Project.Root
  alias MingaEditor.UI.Picker.BufferSource
  alias MingaEditor.UI.Picker.Empty
  alias MingaEditor.UI.Picker.ExtensionListSource
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.ProjectSearchSource
  alias MingaEditor.UI.Picker.Sources.Diagnostics
  alias MingaEditor.UI.Picker.SwitcherNextSteps

  defp rows(%Empty{rows: rows}), do: Enum.map(rows, &{&1.annotation, &1.label})
  defp steps(%Empty{rows: rows}), do: Enum.map(rows, fn %{id: {:next_step, step}} -> step end)

  describe "project search" do
    @tag :tmp_dir
    test "offers each wider search that the query's flags do not already cover", %{tmp_dir: dir} do
      {:ok, root} = Root.directory(dir)

      for {query, coverage, why, offered} <- [
            {"limit_lable", :visible, "Ignored and hidden files were skipped.",
             [
               {"-- -u", "Search ignored files too"},
               {"--hidden", "Search hidden files too"},
               {"-- -uu", "Search all files"}
             ]},
            {"limit_lable -- -u", :with_ignored, "Hidden files were skipped.",
             [{"--hidden", "Search hidden files too"}]},
            {"limit_lable -- --hidden", :with_hidden, "Ignored files were skipped.",
             [{"-- -u", "Search ignored files too"}]}
          ] do
        empty =
          ProjectSearchSource.empty(%{
            query: "",
            total: 0,
            context: %{project_query: query, project_search: {root, coverage}}
          })

        assert empty.title == "No results for “limit_lable”.", query
        assert empty.why == why, query
        assert rows(empty) == offered, query
        assert empty.typing?
      end
    end

    @tag :tmp_dir
    test "widening preserves the pattern, filters and root and does not repeat -u", %{
      tmp_dir: dir
    } do
      {:ok, root} = Root.directory(dir)

      empty =
        ProjectSearchSource.empty(%{
          query: "",
          total: 0,
          context: %{
            project_query: "limit_lable -- -u -g *.ex",
            project_search: {root, :with_ignored}
          }
        })

      assert steps(empty) == [
               {:search, "limit_lable -- -u -g *.ex --hidden", root}
             ]
    end

    @tag :tmp_dir
    test "a scan that already included ignored and hidden files offers only to edit the search",
         %{
           tmp_dir: dir
         } do
      {:ok, root} = Root.directory(dir)

      for query <- ["limit_lable", "limit_lable -- -u -u", "limit_lable -- -u --hidden"] do
        empty =
          ProjectSearchSource.empty(%{
            query: "",
            total: 0,
            context: %{project_query: query, project_search: {root, :all}}
          })

        assert empty.why == "Ignored and hidden files were included."
        assert rows(empty) == [{"SPC s p", "Change the search"}]
        assert steps(empty) == [{:edit, query}]
      end
    end

    test "a filter that hides every result keeps the prompt and says how many there were" do
      empty =
        ProjectSearchSource.empty(%{
          query: "zz ",
          total: 3,
          context: %{project_query: "limit -- -u"}
        })

      assert empty.title == "No result matches “zz”."
      assert empty.why == "3 results for “limit”; keep typing to filter them."
      assert empty.typing?
      assert steps(empty) == [{:edit, "limit -- -u"}]
    end

    test "says nothing without the search it was opened for" do
      assert ProjectSearchSource.empty(%{query: "", total: 0, context: nil}) == nil
    end
  end

  describe "the switcher and file finder" do
    test "a query that matches nothing offers to create the file, then to search the project for it" do
      empty =
        SwitcherNextSteps.empty("chrome_stat_test", SwitcherNextSteps.count(1, "open buffer"))

      assert empty.title == "Nothing matches “chrome_stat_test”."
      assert empty.why == "Searched 1 open buffer."

      assert rows(empty) == [
               {"new file", "Create chrome_stat_test"},
               {"SPC s p", "Search the project for chrome_stat_test"}
             ]

      assert steps(empty) == [
               {:create, "chrome_stat_test"},
               {:search_project, "chrome_stat_test"}
             ]
    end

    test "an empty query offers nothing, and each source counts what it searched" do
      assert SwitcherNextSteps.empty("  ", "3 open buffers") == nil

      assert BufferSource.empty(%{query: "zz", total: 3, context: nil}).why ==
               "Searched 3 open buffers."

      assert FileSource.empty(%{query: "zz", total: 1, context: nil}).why ==
               "Searched 1 file in this project."
    end
  end

  describe "diagnostics" do
    test "an empty list says no language server checks the file and offers to install one" do
      empty = Diagnostics.empty(%{query: "", total: 0, context: %{buffer: nil}})

      assert empty.title == "No problems in this file."
      assert empty.why == "No language server checks this file."

      assert rows(empty) == [
               {"SPC c l I", "Install a language server"},
               {"SPC c l i", "Show what ran"}
             ]

      refute empty.typing?
    end

    test "a query that matches no diagnostic keeps the prompt" do
      empty = Diagnostics.empty(%{query: "warn", total: 2, context: %{buffer: nil}})

      assert empty.title == "No problem matches “warn”."
      assert empty.typing?
    end
  end

  describe "extensions" do
    test "with none installed, says what extensions are for and points at the config" do
      empty = ExtensionListSource.empty(%{query: "", total: 0, context: nil})

      assert empty.title == "No extensions installed."
      assert empty.why == "Extensions add languages, tools and commands."
      assert rows(empty) == [{"SPC f p", "Open your config"}]
      refute empty.typing?
    end
  end
end
