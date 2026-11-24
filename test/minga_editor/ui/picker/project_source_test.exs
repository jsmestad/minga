defmodule MingaEditor.UI.Picker.ProjectSourceTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.Empty
  alias MingaEditor.UI.Picker.ProjectSource

  test "with no known projects, says how Minga learns them and offers to add a folder or open a file" do
    assert %Empty{
             title: "No projects yet.",
             why: "Minga remembers folders you open.",
             typing?: false,
             rows: [add, open]
           } = ProjectSource.empty(%{query: "", total: 0, context: nil})

    assert {add.label, add.annotation, add.id} ==
             {"Add a folder", "SPC p a", {:next_step, {:command, :project_add}}}

    assert {open.label, open.annotation, open.id} ==
             {"Open a file", "SPC f f", {:next_step, {:command, :find_file}}}
  end

  test "a query that matches no known project keeps the prompt and offers the same steps" do
    assert %Empty{title: "No project matches “minga”.", typing?: true, rows: [_, _]} =
             ProjectSource.empty(%{query: "minga", total: 3, context: nil})
  end

  test "selecting a step runs its command after the picker closes" do
    [add, _open] = ProjectSource.empty(%{query: "", total: 0, context: nil}).rows
    assert ProjectSource.on_select(add, %{}) == %{pending_command: :project_add}
  end
end
