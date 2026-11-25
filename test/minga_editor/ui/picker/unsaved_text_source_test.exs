defmodule MingaEditor.UI.Picker.UnsavedTextSourceTest do
  @moduledoc "The list of waiting unsaved text says where each text belongs, how old it is and how it differs from its file."

  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.UnsavedTextSource

  @now 1_800_000_000

  defp entry(overrides) do
    Map.merge(
      %{
        path: "/work/alpha/lib/a.ex",
        swap_path: "/swap/a.4242.swap",
        swap_mtime: @now - 30,
        changed_since?: false,
        project: "/work/alpha",
        file_exists?: true,
        lines: 12,
        changed_lines: 3
      },
      Map.new(overrides)
    )
  end

  test "a row names the file from its project root, with the project as its section" do
    assert [%Item{label: "lib/a.ex", group: "/work/alpha", search_text: "/work/alpha/lib/a.ex"}] =
             UnsavedTextSource.items([entry([])], @now)
  end

  test "a file outside any project is listed by its full path under its own section" do
    assert [%Item{label: "/tmp/notes.txt", group: "Outside a project"}] =
             UnsavedTextSource.items([entry(path: "/tmp/notes.txt", project: nil)], @now)
  end

  test "a path under the home directory is shortened with a tilde" do
    home_file = Path.join(Path.expand("~"), "notes.txt")

    assert [%Item{label: "~/notes.txt"}] =
             UnsavedTextSource.items([entry(path: home_file, project: nil)], @now)
  end

  test "the description says how the text stands against the file" do
    descriptions =
      for overrides <- [
            [changed_lines: 3],
            [changed_lines: 1],
            [changed_lines: nil],
            [file_exists?: false, changed_lines: nil, lines: 1],
            [changed_since?: true, changed_lines: 3]
          ] do
        [%Item{description: description}] = UnsavedTextSource.items([entry(overrides)], @now)
        description
      end

    assert descriptions == [
             "3 lines differ",
             "1 line differs",
             "12 lines, differs from the file",
             "1 line, the file is gone",
             "3 lines differ, the file changed after this text was kept"
           ]
  end

  test "the annotation says when the text was written" do
    ages =
      for seconds <- [5, 59, 60, 3_599, 3_600, 86_399, 86_400, 172_800, 950_400] do
        [%Item{annotation: age}] =
          UnsavedTextSource.items([entry(swap_mtime: @now - seconds)], @now)

        age
      end

    assert ages == [
             "just now",
             "just now",
             "1 min ago",
             "59 min ago",
             "1 h ago",
             "23 h ago",
             "1 day ago",
             "2 days ago",
             "11 days ago"
           ]
  end

  test "rows of one project stay together, and files outside a project come last" do
    entries = [
      entry(path: "/tmp/loose.txt", project: nil, swap_path: "/swap/1.swap"),
      entry(path: "/work/beta/b.ex", project: "/work/beta", swap_path: "/swap/2.swap"),
      entry(path: "/work/alpha/lib/a.ex", project: "/work/alpha", swap_path: "/swap/3.swap"),
      entry(path: "/work/beta/c.ex", project: "/work/beta", swap_path: "/swap/4.swap")
    ]

    assert entries |> UnsavedTextSource.items(@now) |> Enum.map(& &1.group) == [
             "/work/alpha",
             "/work/beta",
             "/work/beta",
             "Outside a project"
           ]
  end

  test "every row offers recover and discard, with recover as the default" do
    [item] = UnsavedTextSource.items([entry([])], @now)

    assert UnsavedTextSource.actions(item) == [{"Recover", :recover}, {"Discard", :discard}]
  end

  test "an empty list says so in one row that does nothing" do
    assert [%Item{id: :empty, label: "No unsaved text is waiting"} = empty] =
             UnsavedTextSource.items([], @now)

    assert UnsavedTextSource.actions(empty) == []
    assert UnsavedTextSource.on_select(empty, :state) == :state
    assert UnsavedTextSource.on_action(:discard, empty, :state) == :state
  end
end
