defmodule Minga.Project.FileTree do
  @moduledoc """
  Pure data structure for a navigable filesystem tree.

  Holds the root path, a set of expanded directories, a cursor position,
  and a show_hidden toggle. The flat list of visible entries is cached in
  the struct after the first computation and invalidated whenever tree
  state changes (expand, collapse, toggle_hidden, refresh, reveal).

  No GenServer; the editor owns this struct in its state.
  """

  alias Minga.Project.FileTree.GitStatus

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
          entries: [entry()] | nil,
          filter: String.t() | nil,
          cached_files: [String.t()] | nil
        }

  @enforce_keys [:root]
  defstruct root: nil,
            expanded: MapSet.new(),
            cursor: 0,
            show_hidden: false,
            width: 30,
            git_status: %{},
            entries: nil,
            filter: nil,
            cached_files: nil

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
    max_idx = max(Enum.count(tree.entries) - 1, 0)
    %{tree | cursor: min(tree.cursor + 1, max_idx)}
  end

  @doc "Selects the visible entry at the given index, clamped to the current visible range."
  @spec select(t(), integer()) :: t()
  def select(%__MODULE__{} = tree, index) when is_integer(index) do
    tree = ensure_entries(tree)
    max_idx = max(Enum.count(tree.entries) - 1, 0)
    %{tree | cursor: index |> max(0) |> min(max_idx)}
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

  @doc "Marks a directory path as expanded and invalidates cached entries."
  @spec expand_path(t(), String.t()) :: t()
  def expand_path(%__MODULE__{} = tree, path) when is_binary(path) do
    invalidate_entries(%{tree | expanded: MapSet.put(tree.expanded, Path.expand(path))})
  end

  @spec expand_or_enter(t(), String.t()) :: t()
  defp expand_or_enter(tree, path) do
    if MapSet.member?(tree.expanded, path) do
      # Already expanded; move cursor to first child.
      # Entries are already cached and valid (no structural change).
      child_idx = tree.cursor + 1

      if child_idx < Enum.count(tree.entries), do: %{tree | cursor: child_idx}, else: tree
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
    max_idx = max(Enum.count(new_tree.entries) - 1, 0)
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
    case cache_filter_entries(tree) do
      entries when is_list(entries) -> %{tree | entries: entries}
      :no_cache -> walk_entries(tree)
    end
  end

  @spec walk_entries(t()) :: t()
  defp walk_entries(%__MODULE__{} = tree) do
    # Span only the actual filesystem walk (the memoized path above returns
    # early), so `[:minga, :file_tree, :walk]` records real walk cost — its
    # entry count and duration — for spotting large-repo overages (#2367).
    entries =
      Minga.Telemetry.span_with_stop_metadata(
        [:minga, :file_tree, :walk],
        %{root: tree.root},
        fn ->
          entries = tree.root |> walk(0, tree, []) |> filter_entries(tree)
          {entries, %{entry_count: Enum.count(entries)}}
        end
      )

    %{tree | entries: entries}
  end

  @doc """
  Attaches a cached flat list of project-relative file paths to the tree.

  When set and a filter is active, `ensure_entries/1` builds the flat list of
  matching entries from this cache in memory instead of walking the filesystem.
  Pass `nil` to drop the cache and fall back to the filesystem walk.
  """
  @spec put_cached_files(t(), [String.t()] | nil) :: t()
  def put_cached_files(%__MODULE__{} = tree, cached_files)
      when is_list(cached_files) or is_nil(cached_files) do
    invalidate_entries(%{tree | cached_files: cached_files})
  end

  # Builds flat filtered entries from the cached relative-path list. Returns
  # `:no_cache` when there is no cache or no active filter, so the caller falls
  # back to the filesystem walk (lazy, non-filtered browsing keeps walking).
  @spec cache_filter_entries(t()) :: [entry()] | :no_cache
  defp cache_filter_entries(%__MODULE__{cached_files: nil}), do: :no_cache

  defp cache_filter_entries(%__MODULE__{cached_files: files} = tree) when is_list(files) do
    if active_filter?(tree), do: build_cache_entries(files, tree), else: :no_cache
  end

  @spec build_cache_entries([String.t()], t()) :: [entry()]
  defp build_cache_entries(files, %__MODULE__{filter: filter, root: root} = tree) do
    needle = String.downcase(filter)

    matches =
      files
      |> Enum.filter(&cache_path_matches?(&1, needle))
      |> maybe_filter_hidden_paths(tree.show_hidden)
      |> Enum.sort()

    last_idx = Enum.count(matches) - 1

    matches
    |> Enum.with_index()
    |> Enum.map(fn {rel_path, idx} -> cache_entry(rel_path, root, idx == last_idx) end)
  end

  @spec cache_path_matches?(String.t(), String.t()) :: boolean()
  defp cache_path_matches?(rel_path, needle) do
    rel_path |> String.downcase() |> String.contains?(needle)
  end

  @spec maybe_filter_hidden_paths([String.t()], boolean()) :: [String.t()]
  defp maybe_filter_hidden_paths(paths, true), do: paths

  defp maybe_filter_hidden_paths(paths, false) do
    Enum.reject(paths, fn rel_path ->
      rel_path |> Path.split() |> Enum.any?(&String.starts_with?(&1, "."))
    end)
  end

  # Filtered cache matches are presented flat (depth 0, no tree guides): the
  # filtered tree is a flat match list, not a nested expanded view (#2377).
  @spec cache_entry(String.t(), String.t(), boolean()) :: entry()
  defp cache_entry(rel_path, root, is_last) do
    %{
      path: Path.join(root, rel_path),
      name: Path.basename(rel_path),
      dir?: false,
      depth: 0,
      last_child?: is_last,
      guides: []
    }
  end

  @doc """
  Computes the filtered visible entries by walking the filesystem.

  Used by the async no-cache filter fallback (#2377 AC4): it runs the same walk
  `ensure_entries/1` would, but returns just the entry list so the walk can run
  off-process and the result be applied (or dropped if stale) later.
  """
  @spec filtered_walk_entries(t()) :: [entry()]
  def filtered_walk_entries(%__MODULE__{} = tree) do
    tree.root |> walk(0, tree, []) |> filter_entries(tree)
  end

  @doc "Replaces the cached visible entries with a precomputed list (clamps the cursor)."
  @spec put_entries(t(), [entry()]) :: t()
  def put_entries(%__MODULE__{} = tree, entries) when is_list(entries) do
    max_idx = max(Enum.count(entries) - 1, 0)
    %{tree | entries: entries, cursor: min(tree.cursor, max_idx)}
  end

  @doc "Refreshes the tree by rescanning the filesystem (clamps cursor)."
  @spec refresh(t()) :: t()
  def refresh(%__MODULE__{} = tree) do
    tree = invalidate_entries(tree) |> ensure_entries()
    max_idx = max(Enum.count(tree.entries) - 1, 0)
    %{tree | cursor: min(tree.cursor, max_idx)}
  end

  @doc "Re-roots the tree while preserving display options."
  @spec reroot(t(), String.t()) :: t()
  def reroot(%__MODULE__{} = tree, root) when is_binary(root) do
    %__MODULE__{
      root: Path.expand(root),
      expanded: MapSet.new([Path.expand(root)]),
      cursor: 0,
      show_hidden: tree.show_hidden,
      width: tree.width,
      git_status: %{},
      filter: tree.filter
    }
  end

  @doc "Starts filtering without invalidating the currently visible unfiltered entries."
  @spec begin_filter(t()) :: t()
  def begin_filter(%__MODULE__{} = tree), do: %{tree | filter: ""}

  @doc "Sets the active substring filter and resets selection to the first match."
  @spec set_filter(t(), String.t()) :: t()
  def set_filter(%__MODULE__{} = tree, filter) when is_binary(filter) do
    invalidate_entries(%{tree | filter: filter, cursor: 0})
  end

  @doc "Clears the active substring filter and resets selection to the first visible entry."
  @spec clear_filter(t()) :: t()
  def clear_filter(%__MODULE__{} = tree) do
    invalidate_entries(%{tree | filter: nil, cursor: 0})
  end

  @doc "Replaces the cached git status map for the tree."
  @spec replace_git_status(t(), GitStatus.status_map()) :: t()
  def replace_git_status(%__MODULE__{} = tree, git_status) when is_map(git_status) do
    %{tree | git_status: git_status}
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

  # A child after a single stat pass: its name, absolute path, whether it is a
  # directory (following symlinks, so a symlink-to-dir counts), and whether it
  # is itself a symlink (so the walk shows it but never descends into it).
  @typep stat_child ::
           {name :: String.t(), full :: String.t(), dir? :: boolean(), symlink? :: boolean()}

  @spec walk(String.t(), non_neg_integer(), t(), [boolean()]) :: [entry()]
  defp walk(dir_path, depth, tree, parent_guides) do
    case File.ls(dir_path) do
      {:ok, names} ->
        sorted =
          names
          |> Enum.reject(&ignored?/1)
          |> maybe_filter_hidden(tree.show_hidden)
          |> Enum.map(&stat_child(dir_path, &1))
          |> Enum.sort_by(fn {name, _full, dir?, _symlink?} ->
            {if(dir?, do: 0, else: 1), String.downcase(name)}
          end)

        last_idx = Enum.count(sorted) - 1

        sorted
        |> Enum.with_index()
        |> Enum.flat_map(fn {child, idx} ->
          walk_entry(child, depth, tree, parent_guides, idx == last_idx)
        end)

      {:error, _} ->
        []
    end
  end

  # Stats a child exactly once (plus a single follow-stat only for symlinks),
  # replacing the previous `File.dir?` (sort) + `File.dir?` (walk_entry) +
  # `File.lstat` (descend guard) per child.
  @spec stat_child(String.t(), String.t()) :: stat_child()
  defp stat_child(dir_path, name) do
    full = Path.join(dir_path, name)
    {dir?, symlink?} = dir_and_symlink(full)
    {name, full, dir?, symlink?}
  end

  # Resolves directory-ness (following symlinks) and symlink-ness with the
  # fewest stats: one `File.lstat` settles real dirs and files; only an entry
  # that is itself a symlink needs a second, following `File.stat` to learn
  # whether its target is a directory.
  @spec dir_and_symlink(String.t()) :: {dir? :: boolean(), symlink? :: boolean()}
  defp dir_and_symlink(full) do
    case File.lstat(full) do
      {:ok, %File.Stat{type: :directory}} -> {true, false}
      {:ok, %File.Stat{type: :symlink}} -> {symlink_target_dir?(full), true}
      {:ok, %File.Stat{}} -> {false, false}
      {:error, _} -> {false, false}
    end
  end

  @spec symlink_target_dir?(String.t()) :: boolean()
  defp symlink_target_dir?(full) do
    case File.stat(full) do
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  end

  @spec walk_entry(stat_child(), non_neg_integer(), t(), [boolean()], boolean()) :: [entry()]
  defp walk_entry({name, full, dir?, symlink?}, depth, tree, parent_guides, is_last) do
    entry = %{
      path: full,
      name: name,
      dir?: dir?,
      depth: depth,
      last_child?: is_last,
      guides: parent_guides
    }

    # Show symlinked directories, but never descend into them (cycle safety).
    if dir? and not symlink? and descend_into_directory?(tree, full) do
      # Children need to know: at this entry's depth, are there more siblings?
      # If this entry is NOT the last child, its depth column should draw │.
      child_guides = Enum.concat(parent_guides, [not is_last])
      [entry | walk(full, depth + 1, tree, child_guides)]
    else
      [entry]
    end
  end

  @spec descend_into_directory?(t(), String.t()) :: boolean()
  defp descend_into_directory?(%__MODULE__{} = tree, path) do
    MapSet.member?(tree.expanded, path) or active_filter?(tree)
  end

  @spec filter_entries([entry()], t()) :: [entry()]
  defp filter_entries(entries, %__MODULE__{filter: nil}), do: entries
  defp filter_entries(entries, %__MODULE__{filter: ""}), do: entries

  defp filter_entries(entries, %__MODULE__{filter: filter, root: root}) do
    needle = String.downcase(filter)
    Enum.filter(entries, &filter_match?(&1, needle, root))
  end

  @spec filter_match?(entry(), String.t(), String.t()) :: boolean()
  defp filter_match?(entry, needle, root) do
    relative_path = Path.relative_to(entry.path, root)

    entry.name |> String.downcase() |> String.contains?(needle) or
      relative_path |> String.downcase() |> String.contains?(needle)
  end

  @spec active_filter?(t()) :: boolean()
  defp active_filter?(%__MODULE__{filter: filter}) when is_binary(filter), do: filter != ""
  defp active_filter?(%__MODULE__{}), do: false

  @spec ignored?(String.t()) :: boolean()
  defp ignored?(name), do: name in Minga.Config.get(:file_find_excludes)

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
