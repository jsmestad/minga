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

    @enforce_keys []
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
