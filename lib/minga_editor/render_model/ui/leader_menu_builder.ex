defmodule MingaEditor.RenderModel.UI.LeaderMenuBuilder do
  @moduledoc """
  Projects the leader keymap into the macOS menu bar's mirror of `SPC` (docs/design/surfaces.md, Mouse).

  The menu bar and which-key read the same trie in the same order (`MingaEditor.RenderModel.UI.WhichKeyBuilder.ordered/2`), so they cannot drift. Each item carries its path after `SPC`, which the menu shows dimmed beside the title as the key sequence (a native menu cannot draw a key sequence as a shortcut), and the ⌘ equivalent the menu puts in its shortcut column.
  """

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.RenderModel.UI.ConfigState
  alias MingaEditor.RenderModel.UI.WhichKeyBuilder
  alias MingaEditor.UI.WhichKey.Binding

  @spec build(Bindings.node_t(), Bindings.node_t()) :: [ConfigState.menu_item()]
  def build(%Bindings.Node{} = leader_trie, filetype_trie \\ Bindings.new()),
    do: leader_trie |> Bindings.with_filetype_group(filetype_trie) |> items([])

  @spec items(Bindings.node_t(), [String.t()]) :: [ConfigState.menu_item()]
  defp items(node, prefix) do
    node
    |> WhichKeyBuilder.ordered(Enum.join(prefix, " "))
    |> Enum.flat_map(fn {section, %Binding{} = binding} ->
      path = prefix ++ [binding.key]
      [item(binding, section, path) | children(node, binding, path)]
    end)
  end

  @spec children(Bindings.node_t(), Binding.t(), [String.t()]) :: [ConfigState.menu_item()]
  defp children(node, %Binding{kind: :group, codepoint: cp, modifiers: mods}, path) do
    case Bindings.lookup(node, {cp, mods}) do
      {:prefix, child} -> items(child, path)
      _other -> []
    end
  end

  defp children(_node, _binding, _path), do: []

  @spec item(Binding.t(), String.t(), [String.t()]) :: ConfigState.menu_item()
  defp item(%Binding{} = binding, section, path) do
    %{
      path: Enum.join(path, " "),
      label: binding.description,
      section: section,
      kind: binding.kind,
      command: command_name(binding.command),
      platform_key: Defaults.platform_key(binding.command) || ""
    }
  end

  @spec command_name(atom() | tuple() | nil) :: String.t()
  defp command_name(command) when is_atom(command) and command != nil, do: Atom.to_string(command)
  defp command_name(_command), do: ""
end
