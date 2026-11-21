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

  test "unregister_source preserves bindings owned by another extension source", %{keymap: keymap} do
    source = {:extension, :active_cleanup}
    other_source = {:extension, :active_cleanup_other}

    assert :ok =
             Active.bind(keymap, :insert, "C-j", :source_cmd, "Source command", source: source)

    assert :ok =
             Active.bind(keymap, :insert, "C-k", :other_source_cmd, "Other source command",
               source: other_source
             )

    {:ok, source_keys} = KeyParser.parse("C-j")
    {:ok, other_keys} = KeyParser.parse("C-k")

    assert {:command, :source_cmd, _desc} =
             keymap |> Active.mode_trie(:insert) |> Bindings.lookup_sequence(source_keys)

    assert {:command, :other_source_cmd, _desc} =
             keymap |> Active.mode_trie(:insert) |> Bindings.lookup_sequence(other_keys)

    assert :ok = Active.unregister_source(keymap, source)

    assert :not_found =
             keymap |> Active.mode_trie(:insert) |> Bindings.lookup_sequence(source_keys)

    assert {:command, :other_source_cmd, _desc} =
             keymap |> Active.mode_trie(:insert) |> Bindings.lookup_sequence(other_keys)
  end

  test "unbind/2 clears source tracking for direct bindings", %{keymap: keymap} do
    source = {:extension, :active_cleanup}
    other_source = {:extension, :active_cleanup_other}

    assert :ok =
             Active.bind(keymap, :insert, "C-j", :source_cmd, "Source command", source: source)

    assert :ok = Active.unbind(keymap, :insert, "C-j")

    {:ok, keys} = KeyParser.parse("C-j")
    assert :not_found = keymap |> Active.mode_trie(:insert) |> Bindings.lookup_sequence(keys)

    assert :ok =
             Active.bind(keymap, :insert, "C-j", :other_cmd, "Other command",
               source: other_source
             )
  end

  test "unbind clears matching source tracking for normalized filetype aliases", %{keymap: keymap} do
    source = {:extension, :active_cleanup}
    other_source = {:extension, :active_cleanup_other}

    assert :ok =
             Active.bind(keymap, :normal, "SPC m c", :source_filetype_cmd, "Source filetype",
               filetype: :elixir,
               source: source
             )

    assert :ok = Active.unbind(keymap, :normal, "c", filetype: :elixir)

    {:ok, keys} = KeyParser.parse("c")
    assert :not_found = keymap |> Active.filetype_trie(:elixir) |> Bindings.lookup_sequence(keys)

    assert :ok =
             Active.bind(keymap, :normal, "SPC m c", :other_filetype_cmd, "Other filetype",
               filetype: :elixir,
               source: other_source
             )
  end

  test "prefixed and bare multi-key filetype aliases differ when replacing defaults", %{
    keymap: keymap
  } do
    rejected_source = {:extension, :active_cleanup}
    owner = {:extension, :active_cleanup_other}
    keys = KeyParser.parse!("t t")

    for spelling <- ["SPC m t", "SPC m t t"] do
      assert {:error, reason} =
               Active.bind(keymap, :normal, spelling, :rejected, "Rejected",
                 filetype: :elixir,
                 source: rejected_source
               )

      assert reason ==
               "key binding #{inspect(spelling)} for :normal already exists and cannot be replaced by #{inspect(rejected_source)}"
    end

    assert {:command, :test_file, _} =
             keymap |> Active.filetype_trie(:elixir) |> Bindings.lookup_sequence(keys)

    assert :ok =
             Active.bind(keymap, :normal, "t t", :replacement, "Replacement",
               filetype: :elixir,
               source: owner
             )

    assert {:command, :replacement, _} =
             keymap |> Active.filetype_trie(:elixir) |> Bindings.lookup_sequence(keys)

    for spelling <- ["t t", "SPC m t t"], source <- [:config, rejected_source] do
      assert {:error, reason} =
               Active.bind(keymap, :normal, spelling, :rejected, "Rejected",
                 filetype: :elixir,
                 source: source
               )

      assert reason ==
               "key binding #{inspect(spelling)} for :normal is already registered by #{inspect(owner)}"
    end

    assert :ok =
             Active.bind(keymap, :normal, "SPC m t t", :rebound, "Rebound",
               filetype: :elixir,
               source: owner
             )

    assert {:command, :rebound, _} =
             keymap |> Active.filetype_trie(:elixir) |> Bindings.lookup_sequence(keys)
  end

  test "filetype false writes globally but source cleanup treats it as scoped", %{keymap: keymap} do
    source = {:extension, :active_cleanup}
    other_source = {:extension, :active_cleanup_other}
    [key] = KeyParser.parse!("C-j")

    assert :ok =
             Active.bind(keymap, :insert, "C-j", :source_cmd, "Source command",
               filetype: false,
               source: source
             )

    assert {:command, :source_cmd} = Active.resolve_mode_binding(keymap, :insert, nil, key)

    assert {:error, reason} =
             Active.bind(keymap, :insert, "C-j", :other_cmd, "Other command",
               filetype: false,
               source: other_source
             )

    assert reason =~ "already registered by #{inspect(source)}"
    assert :ok = Active.unregister_source(keymap, source)
    assert {:command, :source_cmd} = Active.resolve_mode_binding(keymap, :insert, nil, key)
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
