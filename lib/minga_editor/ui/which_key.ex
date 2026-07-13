defmodule MingaEditor.UI.WhichKey do
  @moduledoc """
  Which-key popup utility for Minga.

  Provides key formatting and binding display helpers used when the editor
  is waiting for the next key in a leader-key sequence. After a configurable
  timeout (default 300 ms), a popup is shown listing all available continuations
  of the current prefix. `MingaEditor.Shell.Traditional.WhichKeyWorkflow` owns
  the identity-tagged reveal timer.

  ## Key formatting

  | Input                   | Output  |
  |-------------------------|---------|
  | `{32, 0}`               | `"SPC"` |
  | `{?s, 0x02}`            | `"C-s"` |
  | `{?s, 0x06}`            | `"C-M-s"` |
  | `{?s, 0x04}`            | `"M-s"` |
  | `{?j, 0x00}`            | `"j"`   |
  """

  alias Minga.Keymap.Bindings
  alias MingaEditor.UI.WhichKey.Binding
  alias MingaEditor.UI.WhichKey.Icons

  @typedoc "A formatted binding entry for display."
  @type binding :: Binding.t()

  # ── Key formatting ────────────────────────────────────────────────────────────

  @doc """
  Formats a single `t:Minga.Keymap.Bindings.key/0` tuple into a human-readable string.

  ## Examples

      iex> MingaEditor.UI.WhichKey.format_key({32, 0})
      "SPC"

      iex> MingaEditor.UI.WhichKey.format_key({?s, 0x02})
      "C-s"

      iex> MingaEditor.UI.WhichKey.format_key({?j, 0x00})
      "j"
  """
  @spec format_key(Bindings.key()) :: String.t()
  def format_key(key), do: Bindings.format_key(key)

  # ── Binding display ───────────────────────────────────────────────────────────

  @doc """
  Formats a list of `{key, label}` pairs (as returned by `Minga.Keymap.Bindings.children/1`)
  into a list of `t:binding/0` maps suitable for rendering in a which-key popup.

  ## Examples

      iex> MingaEditor.UI.WhichKey.format_bindings([{{?j, 0}, "Move cursor down"}])
      [%MingaEditor.UI.WhichKey.Binding{key: "j", description: "Move cursor down", kind: :command, icon: nil}]
  """
  @spec format_bindings([{Bindings.key(), String.t() | atom()}]) :: [binding()]
  def format_bindings(children) when is_list(children) do
    Enum.map(children, fn {key, label} ->
      desc = format_label(label)
      kind = if group_label?(desc), do: :group, else: :command
      icon = if kind == :group, do: Icons.for_group(desc)

      %Binding{
        key: format_key(key),
        description: desc,
        kind: kind,
        icon: icon
      }
    end)
  end

  @doc """
  Produces a sorted list of `t:binding/0` maps from the direct children of a
  trie node. This is the primary function used to build which-key popup content.
  """
  @spec bindings_from_node(Bindings.node_t()) :: [binding()]
  def bindings_from_node(node) do
    node
    |> Bindings.children()
    |> format_bindings()
    |> Enum.sort_by(& &1.key)
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  @spec format_label(String.t() | atom()) :: String.t()
  defp format_label(label) when is_binary(label), do: label
  defp format_label(:prefix), do: "+prefix"
  defp format_label(:unknown), do: "?"
  defp format_label(label) when is_atom(label), do: Atom.to_string(label)

  @spec group_label?(String.t()) :: boolean()
  defp group_label?("+" <> _), do: true
  defp group_label?(_), do: false
end
