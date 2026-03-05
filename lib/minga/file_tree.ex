defmodule Minga.FileTree do
  @moduledoc """
  Pure data structure for a navigable filesystem tree.

  Holds the root path, a set of expanded directories, a cursor position,
  and a show_hidden toggle. The flat list of visible entries is computed
  lazily from the filesystem by walking only expanded directories.

  No GenServer; the editor owns this struct in its state.
  """

  @typedoc "A single visible entry in the tree."
  @type entry :: %{
          path: String.t(),
          name: String.t(),
          dir?: boolean(),
          depth: non_neg_integer()
        }

  @type t :: %__MODULE__{
          root: String.t(),
          expanded: MapSet.t(String.t()),
          cursor: non_neg_integer(),
          show_hidden: boolean(),
          width: pos_integer()
        }

  @enforce_keys [:root]
  defstruct root: nil,
            expanded: MapSet.new(),
            cursor: 0,
            show_hidden: false,
            width: 30

  @default_ignore ~w(.git _build deps node_modules .elixir_ls)

  # ── Construction ──────────────────────────────────────────────────────────

  @doc "Creates a new file tree rooted at the given directory path."
  @spec new(String.t(), keyword()) :: t()
  def new(root, opts \\ []) do
    width = Keyword.get(opts, :width, 30)

    %__MODULE__{
      root: Path.expand(root),
      expanded: MapSet.new([Path.expand(root)]),
      width: width
    }
  end

  # ── Navigation ────────────────────────────────────────────────────────────

  @doc "Moves the cursor up by one entry."
  @spec move_up(t()) :: t()
  def move_up(%__MODULE__{cursor: cursor} = tree) do
    %{tree | cursor: max(cursor - 1, 0)}
  end

  @doc "Moves the cursor down by one entry, clamped to the last visible entry."
  @spec move_down(t()) :: t()
  def move_down(%__MODULE__{} = tree) do
    max_idx = max(length(visible_entries(tree)) - 1, 0)
    %{tree | cursor: min(tree.cursor + 1, max_idx)}
  end

  # ── Expand / Collapse ─────────────────────────────────────────────────────

  @doc """
  Toggles expand/collapse for the entry at the cursor.

  If the cursor is on a directory, toggles its expanded state.
  If on a file, this is a no-op.
  """
  @spec toggle_expand(t()) :: t()
  def toggle_expand(%__MODULE__{} = tree) do
    case selected_entry(tree) do
      %{dir?: true, path: path} ->
        if MapSet.member?(tree.expanded, path) do
          %{tree | expanded: MapSet.delete(tree.expanded, path)}
        else
          %{tree | expanded: MapSet.put(tree.expanded, path)}
        end

      _ ->
        tree
    end
  end

  @doc "Collapses the directory at cursor, or if on a file/collapsed dir, collapses the parent."
  @spec collapse(t()) :: t()
  def collapse(%__MODULE__{} = tree) do
    case selected_entry(tree) do
      %{dir?: true, path: path} when path != tree.root ->
        if MapSet.member?(tree.expanded, path) do
          # Collapse this directory
          %{tree | expanded: MapSet.delete(tree.expanded, path)}
        else
          # Already collapsed; jump to parent
          jump_to_parent(tree, path)
        end

      %{path: path} when path != tree.root ->
        # File entry; jump to parent directory
        jump_to_parent(tree, path)

      _ ->
        tree
    end
  end

  @doc "Expands the directory at cursor. No-op on files or already-expanded dirs."
  @spec expand(t()) :: t()
  def expand(%__MODULE__{} = tree) do
    case selected_entry(tree) do
      %{dir?: true, path: path} ->
        expand_or_enter(tree, path)

      _ ->
        tree
    end
  end

  @spec expand_or_enter(t(), String.t()) :: t()
  defp expand_or_enter(tree, path) do
    if MapSet.member?(tree.expanded, path) do
      move_to_first_child(tree)
    else
      %{tree | expanded: MapSet.put(tree.expanded, path)}
    end
  end

  @spec move_to_first_child(t()) :: t()
  defp move_to_first_child(tree) do
    entries = visible_entries(tree)
    child_idx = tree.cursor + 1

    if child_idx < length(entries), do: %{tree | cursor: child_idx}, else: tree
  end

  # ── Visibility toggle ────────────────────────────────────────────────────

  @doc "Toggles visibility of hidden files (dotfiles)."
  @spec toggle_hidden(t()) :: t()
  def toggle_hidden(%__MODULE__{} = tree) do
    new_tree = %{tree | show_hidden: not tree.show_hidden}
    # Clamp cursor to valid range after toggling
    max_idx = max(length(visible_entries(new_tree)) - 1, 0)
    %{new_tree | cursor: min(new_tree.cursor, max_idx)}
  end

  # ── Queries ───────────────────────────────────────────────────────────────

  @doc "Returns the entry at the current cursor position, or nil if empty."
  @spec selected_entry(t()) :: entry() | nil
  def selected_entry(%__MODULE__{} = tree) do
    Enum.at(visible_entries(tree), tree.cursor)
  end

  @doc """
  Returns the flat list of currently visible entries.

  Walks the directory tree starting from root, descending into expanded
  directories. Results are sorted: directories first, then files, both
  alphabetically. Hidden files are excluded unless `show_hidden` is true.
  """
  @spec visible_entries(t()) :: [entry()]
  def visible_entries(%__MODULE__{} = tree) do
    walk(tree.root, 0, tree)
  end

  @doc "Refreshes the tree by recomputing visible entries (clamps cursor)."
  @spec refresh(t()) :: t()
  def refresh(%__MODULE__{} = tree) do
    max_idx = max(length(visible_entries(tree)) - 1, 0)
    %{tree | cursor: min(tree.cursor, max_idx)}
  end

  @doc """
  Highlights the given file path in the tree by expanding its parent
  directories and moving the cursor to it.
  """
  @spec reveal(t(), String.t()) :: t()
  def reveal(%__MODULE__{} = tree, file_path) do
    expanded_path = Path.expand(file_path)

    # Expand all ancestor directories between root and the target
    ancestors = path_ancestors(expanded_path, tree.root)
    new_expanded = Enum.reduce(ancestors, tree.expanded, &MapSet.put(&2, &1))
    tree = %{tree | expanded: new_expanded}

    # Find the entry index and move cursor there
    entries = visible_entries(tree)

    case Enum.find_index(entries, fn e -> e.path == expanded_path end) do
      nil -> tree
      idx -> %{tree | cursor: idx}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  @spec walk(String.t(), non_neg_integer(), t()) :: [entry()]
  defp walk(dir_path, depth, tree) do
    case File.ls(dir_path) do
      {:ok, names} ->
        names
        |> Enum.reject(&ignored?/1)
        |> maybe_filter_hidden(tree.show_hidden)
        |> Enum.sort_by(fn name ->
          full = Path.join(dir_path, name)
          {if(File.dir?(full), do: 0, else: 1), String.downcase(name)}
        end)
        |> Enum.flat_map(&walk_entry(&1, dir_path, depth, tree))

      {:error, _} ->
        []
    end
  end

  @spec walk_entry(String.t(), String.t(), non_neg_integer(), t()) :: [entry()]
  defp walk_entry(name, dir_path, depth, tree) do
    full = Path.join(dir_path, name)
    is_dir = File.dir?(full)
    entry = %{path: full, name: name, dir?: is_dir, depth: depth}

    if is_dir and MapSet.member?(tree.expanded, full) do
      [entry | walk(full, depth + 1, tree)]
    else
      [entry]
    end
  end

  @spec ignored?(String.t()) :: boolean()
  defp ignored?(name), do: name in @default_ignore

  @spec maybe_filter_hidden([String.t()], boolean()) :: [String.t()]
  defp maybe_filter_hidden(names, true), do: names

  defp maybe_filter_hidden(names, false) do
    Enum.reject(names, &String.starts_with?(&1, "."))
  end

  @spec jump_to_parent(t(), String.t()) :: t()
  defp jump_to_parent(tree, path) do
    parent = Path.dirname(path)
    entries = visible_entries(tree)

    case Enum.find_index(entries, fn e -> e.path == parent end) do
      nil -> tree
      idx -> %{tree | cursor: idx}
    end
  end

  @spec path_ancestors(String.t(), String.t()) :: [String.t()]
  defp path_ancestors(path, root) do
    do_ancestors(Path.dirname(path), root, [])
  end

  @spec do_ancestors(String.t(), String.t(), [String.t()]) :: [String.t()]
  defp do_ancestors(path, root, acc) when path == root, do: [root | acc]

  defp do_ancestors(path, root, acc) do
    if String.starts_with?(path, root) do
      do_ancestors(Path.dirname(path), root, [path | acc])
    else
      acc
    end
  end
end
