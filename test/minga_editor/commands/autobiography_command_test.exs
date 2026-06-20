defmodule MingaEditor.Commands.AutobiographyCommandTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias MingaEditor.Commands.Autobiography

  test "provider exports the code-provenance commands" do
    names = Autobiography.__commands__() |> Enum.map(& &1.name)
    assert :code_why in names
    assert :code_autobiography in names
  end

  test "both commands require an active buffer" do
    for cmd <- Autobiography.__commands__() do
      assert cmd.requires_buffer
    end
  end

  test "SPC g w resolves to :code_why and SPC g a to :code_autobiography" do
    trie = Defaults.leader_trie()
    {:prefix, g_node} = Bindings.lookup(trie, {?g, 0})
    assert {:command, :code_why} = Bindings.lookup(g_node, {?w, 0})
    assert {:command, :code_autobiography} = Bindings.lookup(g_node, {?a, 0})
  end
end
