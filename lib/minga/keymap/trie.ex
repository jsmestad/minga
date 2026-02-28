defmodule Minga.Keymap.Trie do
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

      trie = Minga.Keymap.Trie.new()
      trie = Minga.Keymap.Trie.bind(trie, [{?j, 0}], :move_down, "Move cursor down")
      trie = Minga.Keymap.Trie.bind(trie, [{?g, 0}, {?g, 0}], :file_start, "Go to first line")

      {:command, :move_down} = Minga.Keymap.Trie.lookup(trie, {?j, 0})
      {:prefix, node}        = Minga.Keymap.Trie.lookup(trie, {?g, 0})
  """

  @typedoc """
  A single key event: `{codepoint, modifiers}`.

  `codepoint` is the Unicode codepoint (e.g. `?j` = 106).
  `modifiers` is a bitmask: Shift=0x01, Ctrl=0x02, Alt=0x04, Super=0x08.
  """
  @type key :: {codepoint :: non_neg_integer(), modifiers :: non_neg_integer()}

  @typedoc """
  A trie node.

  * `children`    — map of key → child node for continuing sequences
  * `command`     — atom name of the bound command, or `nil` for prefix-only nodes
  * `description` — human-readable label for which-key display, or `nil`
  """
  @type node_t :: %{
          children: %{key() => node_t()},
          command: atom() | nil,
          description: String.t() | nil
        }

  # ── API ─────────────────────────────────────────────────────────────────────

  @doc """
  Creates a new, empty trie root node.
  """
  @spec new() :: node_t()
  def new do
    %{children: %{}, command: nil, description: nil}
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
  """
  @spec bind(node_t(), [key()], atom(), String.t()) :: node_t()
  def bind(%{children: children} = root, [key | rest], command, description)
      when is_atom(command) and is_binary(description) do
    child = Map.get(children, key, new())

    updated_child =
      case rest do
        [] ->
          # Terminal node — set the command
          %{child | command: command, description: description}

        _ ->
          # Intermediate node — recurse
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
  """
  @spec lookup(node_t(), key()) :: {:command, atom()} | {:prefix, node_t()} | :not_found
  def lookup(%{children: children}, key) do
    case Map.fetch(children, key) do
      :error ->
        :not_found

      {:ok, %{command: nil} = child} ->
        {:prefix, child}

      {:ok, %{command: command, children: sub_children} = child} ->
        if map_size(sub_children) > 0 do
          # Could be both a command and a prefix; prefer command
          {:command, command}
        else
          # Pure terminal
          _ = child
          {:command, command}
        end
    end
  end

  @doc """
  Sets a human-readable description on an intermediate (prefix) node without
  binding a command. Useful for labelling leader-key groups like `f → "+file"`.

  Creates intermediate nodes as needed.
  """
  @spec bind_prefix(node_t(), [key()], String.t()) :: node_t()
  def bind_prefix(%{children: children} = root, [key | rest], description)
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
  Returns the direct children of a trie node for which-key display.

  Each entry is a `{key, label}` tuple where `label` is either the
  description string (for a terminal binding) or the command atom (for a
  prefix or unnamed node).
  """
  @spec children(node_t()) :: [{key(), String.t() | atom()}]
  def children(%{children: children}) do
    Enum.map(children, fn {key, %{command: command, description: description, children: sub}} ->
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
