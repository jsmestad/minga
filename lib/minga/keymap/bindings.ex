defmodule Minga.Keymap.Bindings do
  @moduledoc """
  Prefix tree (trie) for key sequence → command bindings.

  Each node in the trie can represent either an intermediate step in a
  multi-key sequence (a prefix node) or a terminal binding (a command node).
  Nodes may simultaneously be a prefix and a command (e.g. `g` could be a
  command and also prefix for `gg`).

  ## Key representation

  A key is a `{codepoint, modifiers}` tuple where `codepoint` is the Unicode
  codepoint of the key and `modifiers` is a bitmask of modifier keys:

  * `0x01` — Shift
  * `0x02` — Ctrl
  * `0x04` — Alt
  * `0x08` — Super

  ## Usage

      trie = Minga.Keymap.Bindings.new()
      trie = Minga.Keymap.Bindings.bind(trie, [{?j, 0}], :move_down, "Move cursor down")
      trie = Minga.Keymap.Bindings.bind(trie, [{?g, 0}, {?g, 0}], :file_start, "Go to first line")

      {:command, :move_down} = Minga.Keymap.Bindings.lookup(trie, {?j, 0})
      {:prefix, node}        = Minga.Keymap.Bindings.lookup(trie, {?g, 0})
  """

  @typedoc """
  A single key event: `{codepoint, modifiers}`.

  `codepoint` is the Unicode codepoint (e.g. `?j` = 106).
  `modifiers` is a bitmask: Shift=0x01, Ctrl=0x02, Alt=0x04, Super=0x08.
  """
  @type key :: {codepoint :: non_neg_integer(), modifiers :: non_neg_integer()}

  defmodule Node do
    @moduledoc "A single node in the keymap trie."

    defstruct children: %{},
              command: nil,
              description: nil

    @type t :: %__MODULE__{
            children: %{Minga.Keymap.Bindings.key() => t()},
            command: atom() | tuple() | nil,
            description: String.t() | nil
          }
  end

  @typedoc "A trie node."
  @type node_t :: Node.t()

  # ── API ─────────────────────────────────────────────────────────────────────

  @doc """
  Creates a new, empty trie root node.

  ## Examples

      iex> trie = Minga.Keymap.Bindings.new()
      iex> Minga.Keymap.Bindings.lookup(trie, {?j, 0})
      :not_found
  """
  @spec new() :: node_t()
  def new do
    %Node{}
  end

  @doc """
  Binds a key sequence to a command in the trie.

  Returns an updated trie root. Intermediate nodes are created as needed.
  Rebinding an existing sequence overwrites the previous binding.

  ## Parameters

  * `root`        — the trie root node
  * `keys`        — non-empty list of `t:key/0` values representing the sequence
  * `command`     — atom name of the command to bind
  * `description` — human-readable description for which-key display

  ## Examples

      iex> trie = Minga.Keymap.Bindings.new()
      iex> trie = Minga.Keymap.Bindings.bind(trie, [{?j, 0}], :move_down, "Move cursor down")
      iex> Minga.Keymap.Bindings.lookup(trie, {?j, 0})
      {:command, :move_down}
      iex> Minga.Keymap.Bindings.lookup(trie, {?k, 0})
      :not_found
  """
  @spec bind(node_t(), [key()], atom() | tuple(), String.t()) :: node_t()
  def bind(%Node{children: children} = root, [key | rest], command, description)
      when (is_atom(command) or is_tuple(command)) and is_binary(description) do
    child = Map.get(children, key, new())

    updated_child =
      case rest do
        [] ->
          %{child | command: command, description: description}

        _ ->
          bind(child, rest, command, description)
      end

    %{root | children: Map.put(children, key, updated_child)}
  end

  @doc """
  Looks up a single key in the trie.

  Returns one of:

  * `{:command, atom()}` — the key sequence is complete and maps to a command
  * `{:prefix, node_t()}` — the key is a valid prefix; the returned node can
    be used as the new root for the next key
  * `:not_found` — the key does not exist in this trie node

  ## Examples

      iex> trie = Minga.Keymap.Bindings.new()
      iex> trie = Minga.Keymap.Bindings.bind(trie, [{?g, 0}, {?g, 0}], :document_start, "Go to first line")
      iex> match?({:prefix, _}, Minga.Keymap.Bindings.lookup(trie, {?g, 0}))
      true
      iex> Minga.Keymap.Bindings.lookup(trie, {?z, 0})
      :not_found
  """
  @spec lookup(node_t(), key()) :: {:command, atom() | tuple()} | {:prefix, node_t()} | :not_found
  def lookup(%Node{children: children}, key) do
    case Map.fetch(children, key) do
      :error ->
        :not_found

      {:ok, %Node{command: nil} = child} ->
        {:prefix, child}

      {:ok, %Node{command: command}} ->
        {:command, command}
    end
  end

  @doc """
  Removes a key sequence binding from the trie.

  Clears the command and description on the terminal node. Prunes empty
  intermediate nodes (nodes with no command and no children) on the way
  back up so the trie doesn't accumulate dead branches.

  Returns the updated trie. No-op if the sequence doesn't exist.

  ## Examples

      iex> trie = Minga.Keymap.Bindings.new()
      iex> trie = Minga.Keymap.Bindings.bind(trie, [{?j, 0}], :move_down, "Move cursor down")
      iex> trie = Minga.Keymap.Bindings.unbind(trie, [{?j, 0}])
      iex> Minga.Keymap.Bindings.lookup(trie, {?j, 0})
      :not_found
  """
  @spec unbind(node_t(), [key()]) :: node_t()
  def unbind(root, []), do: root

  def unbind(%Node{children: children} = root, [key | rest]) do
    case Map.fetch(children, key) do
      :error ->
        root

      {:ok, child} ->
        updated_child =
          case rest do
            [] ->
              %{child | command: nil, description: nil}

            _ ->
              unbind(child, rest)
          end

        if empty_node?(updated_child) do
          %{root | children: Map.delete(children, key)}
        else
          %{root | children: Map.put(children, key, updated_child)}
        end
    end
  end

  @spec empty_node?(node_t()) :: boolean()
  defp empty_node?(%Node{command: nil, children: children}), do: map_size(children) == 0
  defp empty_node?(_), do: false

  @doc """
  Sets a human-readable description on an intermediate (prefix) node without
  binding a command. Useful for labelling leader-key groups like `f → "+file"`.

  Creates intermediate nodes as needed.
  """
  @spec bind_prefix(node_t(), [key()], String.t()) :: node_t()
  def bind_prefix(%Node{children: children} = root, [key | rest], description)
      when is_binary(description) do
    child = Map.get(children, key, new())

    updated_child =
      case rest do
        [] ->
          %{child | description: description}

        _ ->
          bind_prefix(child, rest, description)
      end

    %{root | children: Map.put(children, key, updated_child)}
  end

  @doc """
  Looks up a full key sequence in the trie, walking node by node.

  Returns one of:

  * `{:command, atom(), String.t()}` — the sequence maps to a command with its description
  * `{:prefix, node_t()}` — the sequence is a valid prefix (more keys needed)
  * `:not_found` — no match at some point in the sequence

  ## Examples

      iex> trie = Minga.Keymap.Bindings.new()
      iex> trie = Minga.Keymap.Bindings.bind(trie, [{?g, 0}, {?g, 0}], :document_start, "Go to first line")
      iex> Minga.Keymap.Bindings.lookup_sequence(trie, [{?g, 0}, {?g, 0}])
      {:command, :document_start, "Go to first line"}
      iex> Minga.Keymap.Bindings.lookup_sequence(trie, [{?g, 0}])
      {:prefix, %Minga.Keymap.Bindings.Node{children: %{{103, 0} => %Minga.Keymap.Bindings.Node{children: %{}, command: :document_start, description: "Go to first line"}}, command: nil, description: nil}}
      iex> Minga.Keymap.Bindings.lookup_sequence(trie, [{?z, 0}])
      :not_found
  """
  @spec lookup_sequence(node_t(), [key()]) ::
          {:command, atom(), String.t()} | {:prefix, node_t()} | :not_found
  def lookup_sequence(_node, []), do: :not_found

  def lookup_sequence(node, [key]) do
    case lookup(node, key) do
      {:command, command} ->
        child = node.children[key]
        {:command, command, child.description || ""}

      {:prefix, _} = prefix ->
        prefix

      :not_found ->
        :not_found
    end
  end

  def lookup_sequence(node, [key | rest]) do
    case lookup(node, key) do
      {:prefix, child} -> lookup_sequence(child, rest)
      {:command, _} -> :not_found
      :not_found -> :not_found
    end
  end

  @doc """
  Merges a list of binding tuples into a trie.

  Each binding is a `{key_sequence, command, description}` tuple. Bindings
  are applied in order, so later entries override earlier ones on conflict.

  This is the bulk registration helper for shared binding groups. Scope
  modules call this to include a group's bindings, then apply scope-specific
  bindings on top (which override group bindings on conflict).

  ## Examples

      iex> bindings = [
      ...>   {[{?j, 0}], :move_down, "Move down"},
      ...>   {[{?k, 0}], :move_up, "Move up"}
      ...> ]
      iex> trie = Minga.Keymap.Bindings.merge_bindings(Minga.Keymap.Bindings.new(), bindings)
      iex> {:command, :move_down} = Minga.Keymap.Bindings.lookup(trie, {?j, 0})
      iex> {:command, :move_up} = Minga.Keymap.Bindings.lookup(trie, {?k, 0})
  """
  @spec merge_bindings(node_t(), [{[key()], atom() | tuple(), String.t()}]) :: node_t()
  def merge_bindings(trie, bindings) when is_list(bindings) do
    Enum.reduce(bindings, trie, fn {keys, command, description}, acc ->
      bind(acc, keys, command, description)
    end)
  end

  @doc """
  Merges a list of binding tuples into a trie, excluding specific commands.

  Same as `merge_bindings/2` but skips any binding whose command atom
  appears in the `exclude` list. Use this when a scope includes a shared
  group but needs to override specific commands with different semantics.

  ## Examples

      iex> bindings = [
      ...>   {[{?j, 0}], :move_down, "Move down"},
      ...>   {[{?q, 0}], :quit_editor, "Quit"}
      ...> ]
      iex> trie = Minga.Keymap.Bindings.merge_bindings(Minga.Keymap.Bindings.new(), bindings, exclude: [:quit_editor])
      iex> {:command, :move_down} = Minga.Keymap.Bindings.lookup(trie, {?j, 0})
      iex> :not_found = Minga.Keymap.Bindings.lookup(trie, {?q, 0})
  """
  @spec merge_bindings(node_t(), [{[key()], atom() | tuple(), String.t()}], keyword()) ::
          node_t()
  def merge_bindings(trie, bindings, opts) when is_list(bindings) and is_list(opts) do
    excluded = MapSet.new(Keyword.get(opts, :exclude, []))

    Enum.reduce(bindings, trie, fn {keys, command, description}, acc ->
      if MapSet.member?(excluded, command) do
        acc
      else
        bind(acc, keys, command, description)
      end
    end)
  end

  @doc """
  Merges a named shared group into a trie.

  Convenience wrapper that calls `SharedGroups.get/1` and `merge_bindings/2`.

  ## Examples

      trie = Bindings.new()
      |> Bindings.merge_group(:cua_navigation)
      |> Bindings.bind([{?q, 0}], :quit, "Quit")
  """
  @spec merge_group(node_t(), atom()) :: node_t()
  def merge_group(trie, group_name) when is_atom(group_name) do
    merge_bindings(trie, Minga.Keymap.SharedGroups.get(group_name))
  end

  @doc """
  Merges a named shared group into a trie with exclusions.

  ## Examples

      trie = Bindings.new()
      |> Bindings.merge_group(:cua_navigation, exclude: [:move_up])
  """
  @spec merge_group(node_t(), atom(), keyword()) :: node_t()
  def merge_group(trie, group_name, opts) when is_atom(group_name) and is_list(opts) do
    merge_bindings(trie, Minga.Keymap.SharedGroups.get(group_name), opts)
  end

  # ── Key formatting ───────────────────────────────────────────────────────────

  import Bitwise, only: [band: 2]

  @doc """
  Formats a single `t:key/0` tuple into a human-readable string.

  ## Examples

      iex> Minga.Keymap.Bindings.format_key({32, 0})
      "SPC"

      iex> Minga.Keymap.Bindings.format_key({?s, 0x02})
      "C-s"

      iex> Minga.Keymap.Bindings.format_key({?j, 0x00})
      "j"
  """
  @spec format_key(key()) :: String.t()
  def format_key({32, 0}), do: "SPC"
  def format_key({9, _}), do: "TAB"
  def format_key({13, _}), do: "RET"
  def format_key({27, _}), do: "ESC"

  def format_key({codepoint, modifiers}) do
    char = <<codepoint::utf8>>
    modifier_prefix(modifiers) <> char
  end

  @spec modifier_prefix(non_neg_integer()) :: String.t()
  defp modifier_prefix(modifiers) do
    ctrl = band(modifiers, 0x02) != 0
    alt = band(modifiers, 0x04) != 0
    modifier_string(ctrl, alt)
  end

  @spec modifier_string(boolean(), boolean()) :: String.t()
  defp modifier_string(true, true), do: "C-M-"
  defp modifier_string(true, false), do: "C-"
  defp modifier_string(false, true), do: "M-"
  defp modifier_string(false, false), do: ""

  # ── Children / which-key display ───────────────────────────────────────────

  @doc """
  Returns the direct children of a trie node for which-key display.

  Each entry is a `{key, label}` tuple where `label` is either the
  description string (for a terminal binding) or the command atom (for a
  prefix or unnamed node).

  ## Examples

      iex> trie = Minga.Keymap.Bindings.new()
      iex> trie = Minga.Keymap.Bindings.bind(trie, [{?j, 0}], :move_down, "Move cursor down")
      iex> Minga.Keymap.Bindings.children(trie)
      [{{106, 0}, "Move cursor down"}]
  """
  @spec children(node_t()) :: [{key(), String.t() | atom()}]
  def children(%Node{children: children}) do
    Enum.map(children, fn {key, %Node{command: command, description: description, children: sub}} ->
      label =
        cond do
          description != nil -> description
          command != nil -> command
          map_size(sub) > 0 -> :prefix
          true -> :unknown
        end

      {key, label}
    end)
  end
end
