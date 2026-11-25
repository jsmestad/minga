defmodule MingaEditor.RenderModel.UI.WhichKeyBuilder do
  @moduledoc """
  Builds the semantic which-key panel from the pending key trie node.

  The rows come from the node's children, in the sections `Minga.Keymap.Defaults.which_key_sections/1` declares for the prefix (a bound key no section lists joins a trailing "More"), or in one unnamed section with groups first. Group rows carry their Title Case label with a trailing `›`; frontends render labels, counts and keys verbatim. See docs/design/surfaces.md.
  """

  alias Minga.Keymap.Defaults
  alias Minga.RenderModel.UI.WhichKey
  alias MingaEditor.State.WhichKey, as: WhichKeyState
  alias MingaEditor.UI.WhichKey, as: WhichKeyUI
  alias MingaEditor.UI.WhichKey.Binding
  alias MingaEditor.UI.WhichKey.Counts

  @more "More"

  @hints [%{key: "⌫", label: "back"}, %{key: "esc", label: "close"}]

  @typedoc """
  Build options:

  * `:counts`: live counts by target (`MingaEditor.UI.WhichKey.Counts`).
  * `:platform_keys?`: whether entries show their macOS ⌘ equivalent (native GUI only).
  """
  @type option :: {:counts, Counts.t()} | {:platform_keys?, boolean()}

  @spec build(WhichKeyState.t(), [option()]) :: WhichKey.t()
  def build(state, opts \\ [])

  def build(%WhichKeyState{show: false}, _opts), do: %WhichKey{visible: false}
  def build(%WhichKeyState{node: nil}, _opts), do: %WhichKey{visible: false}

  def build(%WhichKeyState{node: node, prefix_keys: prefix_keys, labels: labels}, opts) do
    counts = Keyword.get(opts, :counts, %{})
    platform_keys? = Keyword.get(opts, :platform_keys?, false)
    group_prefix = group_prefix(prefix_keys)

    entries =
      node
      |> WhichKeyUI.bindings_from_node()
      |> sectioned(Defaults.which_key_sections(group_prefix))
      |> Enum.map(fn {section, binding} ->
        entry(binding, section, group_prefix, counts, platform_keys?)
      end)

    %WhichKey{
      visible: entries != [],
      path: Enum.join(prefix_keys, " "),
      breadcrumb: breadcrumb(prefix_keys, labels),
      count: Counts.text(counts, {:group, group_prefix}),
      hints: @hints,
      entries: entries
    }
  end

  # The formatted sequence after the leader, which names the open group (`"a"` for `SPC a`).
  @spec group_prefix([String.t()]) :: String.t()
  defp group_prefix([_leader | rest]), do: Enum.join(rest, " ")
  defp group_prefix([]), do: ""

  @spec child_prefix(String.t(), String.t()) :: String.t()
  defp child_prefix("", key), do: key
  defp child_prefix(prefix, key), do: prefix <> " " <> key

  @spec sectioned([Binding.t()], [{String.t(), [String.t()]}]) :: [{String.t(), Binding.t()}]
  defp sectioned(bindings, []), do: Enum.map(bindings, &{"", &1})

  defp sectioned(bindings, sections) do
    by_key = Map.new(bindings, &{&1.key, &1})

    declared =
      for {name, keys} <- sections,
          key <- keys,
          Map.has_key?(by_key, key),
          do: {name, by_key[key]}

    listed = MapSet.new(declared, fn {_name, binding} -> binding.key end)
    rest = for binding <- bindings, not MapSet.member?(listed, binding.key), do: {@more, binding}

    # Leftovers join the declared "More" section, so it reads as one column.
    {more, named} = Enum.split_with(declared, fn {name, _binding} -> name == @more end)
    named ++ more ++ rest
  end

  @spec entry(Binding.t(), String.t(), String.t(), Counts.t(), boolean()) :: WhichKey.entry()
  defp entry(%Binding{} = binding, section, group_prefix, counts, platform_keys?) do
    %{
      key: binding.key,
      codepoint: binding.codepoint,
      modifiers: binding.modifiers,
      label: label(binding),
      kind: binding.kind,
      section: section,
      count: Counts.text(counts, count_target(binding, group_prefix)),
      platform_key: platform_key(binding, platform_keys?)
    }
  end

  @spec count_target(Binding.t(), String.t()) :: Counts.target()
  defp count_target(%Binding{kind: :group, key: key}, group_prefix),
    do: {:group, child_prefix(group_prefix, key)}

  defp count_target(%Binding{command: command}, _group_prefix), do: {:command, command}

  @spec platform_key(Binding.t(), boolean()) :: String.t()
  defp platform_key(%Binding{command: command}, true), do: Defaults.platform_key(command) || ""
  defp platform_key(_binding, false), do: ""

  # Groups read like leaves with a trailing chevron ("Session ›"), so both
  # frontends draw the same label from the model instead of inventing it.
  @spec label(Binding.t()) :: String.t()
  defp label(%Binding{kind: :group, description: description}), do: description <> " ›"
  defp label(%Binding{description: description}), do: description

  @spec breadcrumb([String.t()], [String.t()]) :: [WhichKey.crumb()]
  defp breadcrumb(prefix_keys, labels) do
    labels = labels ++ List.duplicate("", max(length(prefix_keys) - length(labels), 0))

    prefix_keys
    |> Enum.zip(labels)
    |> Enum.with_index(1)
    |> Enum.map(fn {{key, label}, depth} ->
      %{
        key: key,
        label: crumb_label(label, depth, length(prefix_keys)),
        path: prefix_keys |> Enum.take(depth) |> Enum.join(" ")
      }
    end)
  end

  # The leader names itself only while it is the open group (`SPC Leader`).
  # Below it the breadcrumb reads `SPC › a Minga`.
  @spec crumb_label(String.t(), pos_integer(), pos_integer()) :: String.t()
  defp crumb_label(_label, 1, depth) when depth > 1, do: ""
  defp crumb_label(label, _crumb, _depth), do: label
end
