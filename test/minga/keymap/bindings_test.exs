defmodule Minga.Keymap.BindingsTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Bindings

  # Convenient key constructors
  defp key(cp, mods \\ 0), do: {cp, mods}

  # Modifier shortcuts
  @ctrl 0x02

  describe "new/0" do
    test "returns a node with no children, no command, no description" do
      node = Bindings.new()
      assert node.children == %{}
      assert node.command == nil
      assert node.description == nil
    end
  end

  describe "bind/4 — single key" do
    test "binds a single-key sequence" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?j)], :move_down, "Move down")

      assert {:command, :move_down} = Bindings.lookup(trie, key(?j))
    end

    test "binding stores the description on the terminal node" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?h)], :move_left, "Move left")

      {:ok, child} = Map.fetch(trie.children, key(?h))
      assert child.description == "Move left"
    end

    test "multiple single-key bindings coexist" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?h)], :move_left, "Move left")
        |> Bindings.bind([key(?l)], :move_right, "Move right")

      assert {:command, :move_left} = Bindings.lookup(trie, key(?h))
      assert {:command, :move_right} = Bindings.lookup(trie, key(?l))
    end
  end

  describe "bind/4 — multi-key sequences" do
    test "binds a two-key sequence" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?g), key(?g)], :file_start, "Go to first line")

      # First key returns a prefix node
      assert {:prefix, node} = Bindings.lookup(trie, key(?g))
      # Second key in the prefix node resolves to the command
      assert {:command, :file_start} = Bindings.lookup(node, key(?g))
    end

    test "binds a three-key leader sequence" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?\s), key(?f), key(?s)], :save, "Save file")

      assert {:prefix, level1} = Bindings.lookup(trie, key(?\s))
      assert {:prefix, level2} = Bindings.lookup(level1, key(?f))
      assert {:command, :save} = Bindings.lookup(level2, key(?s))
    end

    test "a key can be simultaneously a prefix and a command" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?g)], :go, "Go")
        |> Bindings.bind([key(?g), key(?g)], :file_start, "First line")

      # ?g alone is a command
      assert {:command, :go} = Bindings.lookup(trie, key(?g))
      # but the prefix subtrie also exists
      {:ok, g_node} = Map.fetch(trie.children, key(?g))
      assert {:command, :file_start} = Bindings.lookup(g_node, key(?g))
    end
  end

  describe "lookup/2" do
    test "returns :not_found for a key not in the trie" do
      trie = Bindings.new()
      assert :not_found = Bindings.lookup(trie, key(?z))
    end

    test "returns :not_found after the sequence is exhausted" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?g), key(?g)], :file_start, "First line")

      # ?g is a valid prefix node — but ?x is not a child of that node
      {:prefix, g_node} = Bindings.lookup(trie, key(?g))
      assert :not_found = Bindings.lookup(g_node, key(?x))
    end

    test "returns {:prefix, _} for an intermediate node" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?d), key(?w)], :delete_word, "Delete word")

      assert {:prefix, _node} = Bindings.lookup(trie, key(?d))
    end

    test "modifier keys are part of the trie key" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?s, @ctrl)], :save, "Save")

      assert {:command, :save} = Bindings.lookup(trie, key(?s, @ctrl))
      assert :not_found = Bindings.lookup(trie, key(?s, 0))
    end
  end

  describe "bind/4 — overwriting" do
    test "rebinding the same key sequence overwrites the command" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?s, @ctrl)], :save, "Save")
        |> Bindings.bind([key(?s, @ctrl)], :save_as, "Save as")

      assert {:command, :save_as} = Bindings.lookup(trie, key(?s, @ctrl))
    end

    test "rebinding updates the description" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?h)], :move_left, "Old description")
        |> Bindings.bind([key(?h)], :move_left, "New description")

      {:ok, child} = Map.fetch(trie.children, key(?h))
      assert child.description == "New description"
    end

    test "rebinding a sequence does not affect sibling sequences" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?h)], :move_left, "Move left")
        |> Bindings.bind([key(?l)], :move_right, "Move right")
        |> Bindings.bind([key(?h)], :move_left_fast, "Move left fast")

      assert {:command, :move_right} = Bindings.lookup(trie, key(?l))
    end
  end

  describe "children/1" do
    test "returns an empty list for a leaf node" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?j)], :move_down, "Move down")

      {:ok, leaf} = Map.fetch(trie.children, key(?j))
      assert Bindings.children(leaf) == []
    end

    test "returns all direct children of a node" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?g), key(?g)], :file_start, "First line")
        |> Bindings.bind([key(?g), key(?e)], :end_of_word, "End of word")

      {:prefix, g_node} = Bindings.lookup(trie, key(?g))
      kids = Bindings.children(g_node)

      keys = Enum.map(kids, fn {k, _} -> k end)
      assert key(?g) in keys
      assert key(?e) in keys
      assert length(kids) == 2
    end

    test "label for a terminal binding is the description string" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?j)], :move_down, "Move cursor down")

      [{_key, label}] = Bindings.children(trie)
      assert label == "Move cursor down"
    end

    test "returns children from the root node for which-key display" do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?h)], :move_left, "Move left")
        |> Bindings.bind([key(?j)], :move_down, "Move down")
        |> Bindings.bind([key(?k)], :move_up, "Move up")
        |> Bindings.bind([key(?l)], :move_right, "Move right")

      kids = Bindings.children(trie)
      assert length(kids) == 4
      assert Enum.all?(kids, fn {_k, v} -> is_binary(v) end)
    end
  end

  describe "integration — build a minimal normal-mode keymap" do
    setup do
      trie =
        Bindings.new()
        |> Bindings.bind([key(?h)], :move_left, "Move left")
        |> Bindings.bind([key(?j)], :move_down, "Move down")
        |> Bindings.bind([key(?k)], :move_up, "Move up")
        |> Bindings.bind([key(?l)], :move_right, "Move right")
        |> Bindings.bind([key(?d), key(?d)], :delete_line, "Delete line")
        |> Bindings.bind([key(?d), key(?w)], :delete_word, "Delete word")
        |> Bindings.bind([key(?g), key(?g)], :file_start, "Go to first line")
        |> Bindings.bind([key(?G)], :file_end, "Go to last line")
        |> Bindings.bind([key(?s, @ctrl)], :save, "Save file")

      {:ok, trie: trie}
    end

    test "single-key commands resolve immediately", %{trie: trie} do
      assert {:command, :move_left} = Bindings.lookup(trie, key(?h))
      assert {:command, :move_down} = Bindings.lookup(trie, key(?j))
      assert {:command, :move_up} = Bindings.lookup(trie, key(?k))
      assert {:command, :move_right} = Bindings.lookup(trie, key(?l))
      assert {:command, :file_end} = Bindings.lookup(trie, key(?G))
    end

    test "double-key sequences resolve through prefix nodes", %{trie: trie} do
      assert {:prefix, d_node} = Bindings.lookup(trie, key(?d))
      assert {:command, :delete_line} = Bindings.lookup(d_node, key(?d))
      assert {:command, :delete_word} = Bindings.lookup(d_node, key(?w))

      assert {:prefix, g_node} = Bindings.lookup(trie, key(?g))
      assert {:command, :file_start} = Bindings.lookup(g_node, key(?g))
    end

    test "ctrl-modified key resolves correctly", %{trie: trie} do
      assert {:command, :save} = Bindings.lookup(trie, key(?s, @ctrl))
    end

    test "unknown keys return :not_found", %{trie: trie} do
      assert :not_found = Bindings.lookup(trie, key(?z))
      assert :not_found = Bindings.lookup(trie, key(?q, @ctrl))
    end

    test "children of root covers all top-level keys", %{trie: trie} do
      keys = trie |> Bindings.children() |> Enum.map(fn {k, _} -> k end)

      # h, j, k, l, d, g, G, ctrl+s
      assert key(?h) in keys
      assert key(?j) in keys
      assert key(?k) in keys
      assert key(?l) in keys
      assert key(?d) in keys
      assert key(?g) in keys
      assert key(?G) in keys
      assert key(?s, @ctrl) in keys
    end
  end

  describe "lookup_sequence/2" do
    test "single-key command returns command with description" do
      trie = Bindings.new()
      trie = Bindings.bind(trie, [key(?j)], :move_down, "Move cursor down")

      assert {:command, :move_down, "Move cursor down"} =
               Bindings.lookup_sequence(trie, [key(?j)])
    end

    test "multi-key command returns command with description" do
      trie = Bindings.new()
      trie = Bindings.bind(trie, [key(?g), key(?g)], :document_start, "Go to first line")

      assert {:command, :document_start, "Go to first line"} =
               Bindings.lookup_sequence(trie, [key(?g), key(?g)])
    end

    test "partial sequence returns prefix" do
      trie = Bindings.new()
      trie = Bindings.bind(trie, [key(?g), key(?g)], :document_start, "Go to first line")

      assert {:prefix, _node} = Bindings.lookup_sequence(trie, [key(?g)])
    end

    test "unbound sequence returns not_found" do
      trie = Bindings.new()
      trie = Bindings.bind(trie, [key(?j)], :move_down, "Move cursor down")

      assert :not_found = Bindings.lookup_sequence(trie, [key(?z)])
    end

    test "empty sequence returns not_found" do
      trie = Bindings.new()
      assert :not_found = Bindings.lookup_sequence(trie, [])
    end
  end
end
