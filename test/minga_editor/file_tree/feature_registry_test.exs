defmodule MingaEditor.FileTree.FeatureRegistryTest do
  # Mutates the global input handler registry.
  use ExUnit.Case, async: false

  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FileTree.Feature, as: FileTreeFeature
  alias MingaEditor.Input
  alias MingaEditor.State.FileTree, as: FileTreeState

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})
    on_exit(fn -> Input.reset_handlers() end)
    %{sidebar_registry: table}
  end

  test "FileTree handler uses a built-in source that extension cleanup cannot remove", %{
    sidebar_registry: table
  } do
    Input.reset_handlers()
    :ok = FileTreeFeature.register_contributions(%FileTreeState{}, table)

    handlers = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})

    assert FileTreeFeature.input_source() == :builtin
    assert Enum.count(handlers, &(&1 == MingaEditor.Input.FileTreeHandler)) == 1

    :ok = Input.unregister_source({:extension, :file_tree})
    handlers = Input.surface_handlers(%{editing_model: Minga.Editing.Model.Vim})

    assert Enum.count(handlers, &(&1 == MingaEditor.Input.FileTreeHandler)) == 1
  end
end
