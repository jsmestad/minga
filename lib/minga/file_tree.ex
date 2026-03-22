defmodule Minga.FileTree do
  @moduledoc """
  Pure data structure for a navigable filesystem tree.

  Holds the root path, a set of expanded directories, a cursor position,
  and a show_hidden toggle. The flat list of visible entries is cached in
  the struct after the first computation and invalidated whenever tree
  state changes (expand, collapse, toggle_hidden, refresh, reveal).

  No GenServer; the editor owns this struct in its state.
  """

  alias Minga.FileTree.GitStatus

  @typedoc """
  A single visible entry in the tree.

  The `guides` field is a list of booleans, one per ancestor depth level
  (index 0 = depth 0, index 1 = depth 1, etc.). `true` means the ancestor
  at that depth has more siblings below this entry (draw `│`), `false`
  means it was the last child (draw blank). The renderer uses this plus
  `last_child?` to pick `├──` vs `└──` at the entry's own depth.
  """
  @type entry :: %{
          path: String.t(),
          name: String.t(),
          dir?: boolean(),
          depth: non_neg_integer(),
          last_child?: boolean(),
          guides: [boolean()]
        }

  @type t :: %__MODULE__{
          root: String.t(),
          expanded: MapSet.t(String.t()),
          cursor: non_neg_integer(),
          show_hidden: boolean(),
          width: pos_integer(),
          git_status: GitStatus.status_map(),
          entries: [entry()] | nil
        }

  @enforce_keys [:root]
  defstruct root: nil,
            expanded: MapSet.new(),
            cursor: 0,
            show_hidden: false,
            width: 30,
            git_status: %{},
            entries: nil

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
    tree = ensure_entries(tree)
    max_idx = max(length(tree.entries) - 1, 0)
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
    cached = ensure_entries(tree)

    case Enum.at(cached.entries, cached.cursor) do
      %{dir?: true, path: path} ->
        if MapSet.member?(cached.expanded, path) do
          invalidate_entries(%{cached | expanded: MapSet.delete(cached.expanded, path)})
        else
          invalidate_entries(%{cached | expanded: MapSet.put(cached.expanded, path)})
        end

      _ ->
        cached
    end
  end

  @doc "Collapses all directories, keeping only the root expanded. Resets cursor to 0."
  @spec collapse_all(t()) :: t()
  def collapse_all(%__MODULE__{} = tree) do
    invalidate_entries(%{tree | expanded: MapSet.new([tree.root]), cursor: 0})
  end

  @doc "Collapses the directory at cursor, or if on a file/collapsed dir, collapses the parent."
  @spec collapse(t()) :: t()
  def collapse(%__MODULE__{} = tree) do
    cached = ensure_entries(tree)

    case Enum.at(cached.entries, cached.cursor) do
      %{dir?: true, path: path} when path != cached.root ->
        if MapSet.member?(cached.expanded, path) do
          # Collapse this directory
          invalidate_entries(%{cached | expanded: MapSet.delete(cached.expanded, path)})
        else
          # Already collapsed; jump to parent
          jump_to_parent(cached, path)
        end

      %{path: path} when path != cached.root ->
        # File entry; jump to parent directory
        jump_to_parent(cached, path)

      _ ->
        cached
    end
  end

  @doc "Expands the directory at cursor. No-op on files or already-expanded dirs."
  @spec expand(t()) :: t()
  def expand(%__MODULE__{} = tree) do
    cached = ensure_entries(tree)

    case Enum.at(cached.entries, cached.cursor) do
      %{dir?: true, path: path} ->
        expand_or_enter(cached, path)

      _ ->
        cached
    end
  end

  @spec expand_or_enter(t(), String.t()) :: t()
  defp expand_or_enter(tree, path) do
    if MapSet.member?(tree.expanded, path) do
      # Already expanded; move cursor to first child.
      # Entries are already cached and valid (no structural change).
      child_idx = tree.cursor + 1

      if child_idx < length(tree.entries), do: %{tree | cursor: child_idx}, else: tree
    else
      invalidate_entries(%{tree | expanded: MapSet.put(tree.expanded, path)})
    end
  end

  # ── Visibility toggle ────────────────────────────────────────────────────

  @doc "Toggles visibility of hidden files (dotfiles)."
  @spec toggle_hidden(t()) :: t()
  def toggle_hidden(%__MODULE__{} = tree) do
    new_tree = invalidate_entries(%{tree | show_hidden: not tree.show_hidden})
    new_tree = ensure_entries(new_tree)
    # Clamp cursor to valid range after toggling
    max_idx = max(length(new_tree.entries) - 1, 0)
    %{new_tree | cursor: min(new_tree.cursor, max_idx)}
  end

  # ── Queries ───────────────────────────────────────────────────────────────

  @doc """
  Returns the entry at the current cursor position, or nil if empty.

  This reads from the cached entries if available. For performance-sensitive
  callers that will call this repeatedly, call `ensure_entries/1` first to
  populate the cache; subsequent calls on the same struct will use it.
  """
  @spec selected_entry(t()) :: entry() | nil
  def selected_entry(%__MODULE__{} = tree) do
    Enum.at(visible_entries(tree), tree.cursor)
  end

  @doc """
  Returns the flat list of currently visible entries.

  Returns cached entries if available. Otherwise walks the directory tree
  starting from root, descending into expanded directories. Results are
  sorted: directories first, then files, both alphabetically. Hidden
  files are excluded unless `show_hidden` is true.

  Note: this returns only the list, not the updated struct. If the cache
  was empty, the computed entries are not stored back in the struct.
  Callers that need repeated access should call `ensure_entries/1` first
  to populate the cache, then read `.entries` or call this function on
  the returned struct.
  """
  @spec visible_entries(t()) :: [entry()]
  def visible_entries(%__MODULE__{} = tree) do
    ensure_entries(tree).entries
  end

  @doc """
  Returns the tree with entries guaranteed to be populated.

  If entries are already cached, returns the tree unchanged.
  Otherwise computes entries from the filesystem and caches them.
  Use this when you need to read entries multiple times from the
  same tree without redundant filesystem walks.
  """
  @spec ensure_entries(t()) :: t()
  def ensure_entries(%__MODULE__{entries: entries} = tree) when is_list(entries), do: tree

  def ensure_entries(%__MODULE__{} = tree) do
    %{tree | entries: walk(tree.root, 0, tree, [])}
  end

  @doc "Refreshes the tree by rescanning the filesystem (clamps cursor)."
  @spec refresh(t()) :: t()
  def refresh(%__MODULE__{} = tree) do
    tree = invalidate_entries(tree) |> ensure_entries()
    max_idx = max(length(tree.entries) - 1, 0)
    %{tree | cursor: min(tree.cursor, max_idx)}
  end

  @doc "Refreshes git status for the tree root. Returns the updated tree."
  @spec refresh_git_status(t()) :: t()
  def refresh_git_status(%__MODULE__{} = tree) do
    %{tree | git_status: GitStatus.compute(tree.root)}
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
    tree = invalidate_entries(%{tree | expanded: new_expanded}) |> ensure_entries()

    # Find the entry index and move cursor there
    case Enum.find_index(tree.entries, fn e -> e.path == expanded_path end) do
      nil -> tree
      idx -> %{tree | cursor: idx}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  @spec invalidate_entries(t()) :: t()
  defp invalidate_entries(%__MODULE__{} = tree), do: %{tree | entries: nil}

  @spec walk(String.t(), non_neg_integer(), t(), [boolean()]) :: [entry()]
  defp walk(dir_path, depth, tree, parent_guides) do
    case File.ls(dir_path) do
      {:ok, names} ->
        sorted =
          names
          |> Enum.reject(&ignored?/1)
          |> maybe_filter_hidden(tree.show_hidden)
          |> Enum.sort_by(fn name ->
            full = Path.join(dir_path, name)
            {if(File.dir?(full), do: 0, else: 1), String.downcase(name)}
          end)

        last_idx = length(sorted) - 1

        sorted
        |> Enum.with_index()
        |> Enum.flat_map(fn {name, idx} ->
          walk_entry(name, dir_path, depth, tree, parent_guides, idx == last_idx)
        end)

      {:error, _} ->
        []
    end
  end

  @spec walk_entry(String.t(), String.t(), non_neg_integer(), t(), [boolean()], boolean()) ::
          [entry()]
  defp walk_entry(name, dir_path, depth, tree, parent_guides, is_last) do
    full = Path.join(dir_path, name)
    is_dir = File.dir?(full)

    entry = %{
      path: full,
      name: name,
      dir?: is_dir,
      depth: depth,
      last_child?: is_last,
      guides: parent_guides
    }

    if is_dir and MapSet.member?(tree.expanded, full) do
      # Children need to know: at this entry's depth, are there more siblings?
      # If this entry is NOT the last child, its depth column should draw │.
      child_guides = parent_guides ++ [not is_last]
      [entry | walk(full, depth + 1, tree, child_guides)]
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
    tree = ensure_entries(tree)

    case Enum.find_index(tree.entries, fn e -> e.path == parent end) do
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
