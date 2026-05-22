defmodule Minga.Keymap.ActiveSourceCleanupTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Active
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.KeyParser

  setup do
    {:ok, keymap} = Active.start_link(name: nil)
    {:ok, keymap: keymap}
  end

  test "unregister_source removes filetype-scoped bindings", %{keymap: keymap} do
    source = {:extension, :active_cleanup}

    assert :ok =
             Active.bind(keymap, :normal, "SPC m Z", :source_filetype_cmd, "Source filetype",
               filetype: :elixir,
               source: source
             )

    {:ok, keys} = KeyParser.parse("Z")

    assert {:command, :source_filetype_cmd, _desc} =
             keymap |> Active.filetype_trie(:elixir) |> Bindings.lookup_sequence(keys)

    assert :ok = Active.unregister_source(keymap, source)
    assert :not_found = keymap |> Active.filetype_trie(:elixir) |> Bindings.lookup_sequence(keys)
  end

  test "unregister_source removes scope-specific bindings", %{keymap: keymap} do
    source = {:extension, :active_cleanup}

    assert :ok =
             Active.bind(keymap, {:agent, :normal}, "Q", :source_scope_cmd, "Source scope",
               source: source
             )

    {:ok, keys} = KeyParser.parse("Q")

    assert {:command, :source_scope_cmd, _desc} =
             keymap |> Active.scope_trie(:agent, :normal) |> Bindings.lookup_sequence(keys)

    assert :ok = Active.unregister_source(keymap, source)

    assert :not_found =
             keymap |> Active.scope_trie(:agent, :normal) |> Bindings.lookup_sequence(keys)
  end

  test "extension bindings cannot replace config-owned bindings", %{keymap: keymap} do
    source = {:extension, :active_cleanup}

    assert :ok = Active.bind(keymap, :insert, "C-j", :config_cmd, "Config command")

    assert {:error, reason} =
             Active.bind(keymap, :insert, "C-j", :extension_cmd, "Extension command",
               source: source
             )

    assert String.contains?(reason, "already registered")
  end
end
