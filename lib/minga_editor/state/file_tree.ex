defmodule MingaEditor.State.FileTree do
  @moduledoc """
  File tree sub-state: tree data, focus, and backing buffer.

  Wraps the file-tree-related fields from EditorState into a single
  struct with query and mutation helpers. Includes inline editing state
  for new file, new folder, and rename operations.
  """

  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.FilterWalk
  alias MingaEditor.FileTree.ProjectCache
  alias MingaEditor.State.FileTree.ClipboardMark

  @typedoc """
  Inline editing state for creating files/folders or renaming entries.

  When non-nil, the user is actively typing a filename in the tree.
  The `index` is the visual position in the visible entry list where
  the editing row appears. For new file/folder, this is the insertion
  point. For rename, this is the entry being renamed.
  """
  @type editing_type :: :new_file | :new_folder | :rename

  @type editing :: %{
          index: non_neg_integer(),
          text: String.t(),
          type: editing_type(),
          original_name: String.t() | nil
        }

  @type clipboard_operation :: ClipboardMark.operation()
  @type clipboard_mark :: ClipboardMark.t()

  @typedoc "Explicit presentation state for the file tree sidebar."
  @type tree_status :: :hidden | :loading | :empty | :ready | {:error, String.t()}

  @typedoc "File tree sub-state."
  @type t :: %__MODULE__{
          tree: FileTree.t() | nil,
          focused: boolean(),
          buffer: pid() | nil,
          editing: editing() | nil,
          project_root: String.t() | nil,
          original_root: String.t() | nil,
          tree_status: tree_status(),
          tree_width: pos_integer(),
          refresh_timer: reference() | nil,
          refresh_inflight: reference() | nil,
          refresh_pending?: boolean(),
          clipboard_mark: clipboard_mark() | nil,
          filtering: boolean(),
          help_visible: boolean()
        }

  defstruct tree: nil,
            focused: false,
            buffer: nil,
            editing: nil,
            project_root: nil,
            original_root: nil,
            tree_status: :hidden,
            tree_width: 30,
            refresh_timer: nil,
            refresh_inflight: nil,
            refresh_pending?: false,
            clipboard_mark: nil,
            filtering: false,
            help_visible: false

  @doc "Returns true when the file tree is open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{tree: nil}), do: false
  def open?(%__MODULE__{}), do: true

  @doc "Returns true when the file tree is open and focused."
  @spec focused?(t()) :: boolean()
  def focused?(%__MODULE__{tree: %FileTree{}, focused: true}), do: true
  def focused?(%__MODULE__{}), do: false

  @doc "Returns true when inline editing is active."
  @spec editing?(t()) :: boolean()
  def editing?(%__MODULE__{editing: %{}}), do: true
  def editing?(%__MODULE__{}), do: false

  @doc "Returns the explicit presentation status for the file tree."
  @spec status(t()) :: tree_status()
  def status(%__MODULE__{tree: nil, tree_status: status}) when status in [:loading], do: status
  def status(%__MODULE__{tree: nil, tree_status: {:error, _reason} = status}), do: status
  def status(%__MODULE__{tree: nil}), do: :hidden

  def status(%__MODULE__{tree: %FileTree{}, tree_status: :hidden} = ft),
    do: classify_tree(ft.tree)

  def status(%__MODULE__{tree: %FileTree{}, tree_status: status})
      when status in [:loading, :empty, :ready], do: status

  def status(%__MODULE__{tree: %FileTree{}, tree_status: {:error, _reason} = status}), do: status

  @doc "Returns true when the explicit tree status should occupy the sidebar."
  @spec visible_status?(tree_status()) :: boolean()
  def visible_status?(:hidden), do: false
  def visible_status?(_status), do: true

  @doc "Marks the file tree as focused."
  @spec focus(t()) :: t()
  def focus(%__MODULE__{} = ft), do: %{ft | focused: true}

  @doc "Marks the file tree as unfocused."
  @spec unfocus(t()) :: t()
  def unfocus(%__MODULE__{} = ft), do: %{ft | focused: false}

  @doc "Returns the tree width, preserving the last sidebar width while state-only payloads are visible."
  @spec width(t()) :: pos_integer()
  def width(%__MODULE__{tree: nil, tree_width: width}), do: width
  def width(%__MODULE__{tree: %FileTree{width: width}}), do: width

  @doc "Opens the tree with the given data, buffer, and focused state."
  @spec open(t(), FileTree.t(), pid() | nil) :: t()
  def open(%__MODULE__{} = ft, tree, buffer) do
    tree = ensure_tree_entries(tree)

    %{
      ft
      | tree: tree,
        focused: true,
        buffer: buffer,
        project_root: tree.root,
        original_root: ft.original_root || tree.root,
        tree_status: classify_tree(tree),
        tree_width: tree.width
    }
  end

  @doc "Replaces the backing tree and refreshes the presentation status."
  @spec replace_tree(t(), FileTree.t()) :: t()
  def replace_tree(%__MODULE__{} = ft, %FileTree{} = tree) do
    tree = ensure_tree_entries(tree)

    %{
      ft
      | tree: tree,
        project_root: tree.root,
        tree_status: classify_tree(tree),
        tree_width: tree.width
    }
  end

  @doc "Marks the sidebar as loading."
  @spec loading(t()) :: t()
  def loading(%__MODULE__{} = ft) do
    %{
      ft
      | focused: false,
        editing: nil,
        filtering: false,
        help_visible: false,
        tree_status: :loading
    }
  end

  @doc "Updates the project root associated with the file tree."
  @spec set_project_root(t(), String.t() | nil) :: t()
  def set_project_root(%__MODULE__{} = ft, nil), do: %{ft | project_root: nil, original_root: nil}

  def set_project_root(%__MODULE__{} = ft, root) when is_binary(root) do
    expanded = Path.expand(root)
    %{ft | project_root: expanded, original_root: expanded}
  end

  @doc "Returns true when a filesystem refresh timer is pending."
  @spec refresh_scheduled?(t()) :: boolean()
  def refresh_scheduled?(%__MODULE__{refresh_timer: ref}) when is_reference(ref), do: true
  def refresh_scheduled?(%__MODULE__{}), do: false

  @doc "Stores the pending filesystem refresh timer reference."
  @spec schedule_refresh(t(), reference()) :: t()
  def schedule_refresh(%__MODULE__{} = ft, ref) when is_reference(ref) do
    %{ft | refresh_timer: ref}
  end

  @doc "Clears the pending filesystem refresh timer reference."
  @spec clear_refresh(t()) :: t()
  def clear_refresh(%__MODULE__{} = ft), do: %{ft | refresh_timer: nil}

  @doc "Returns true when an async refresh Task is currently in flight."
  @spec refresh_inflight?(t()) :: boolean()
  def refresh_inflight?(%__MODULE__{refresh_inflight: ref}) when is_reference(ref), do: true
  def refresh_inflight?(%__MODULE__{}), do: false

  @doc "Returns the token of the in-flight refresh Task, or nil when none is running."
  @spec refresh_inflight_token(t()) :: reference() | nil
  def refresh_inflight_token(%__MODULE__{refresh_inflight: ref}), do: ref

  @doc "Returns true when another refresh was requested while one was in flight."
  @spec refresh_pending?(t()) :: boolean()
  def refresh_pending?(%__MODULE__{refresh_pending?: pending?}), do: pending?

  @doc """
  Marks an async refresh as in flight under `token` and clears the debounce timer.

  Also clears any `refresh_pending?` flag: the freshly spawned Task supersedes a
  request that was coalesced while a previous Task was running.
  """
  @spec begin_inflight_refresh(t(), reference()) :: t()
  def begin_inflight_refresh(%__MODULE__{} = ft, token) when is_reference(token) do
    %{ft | refresh_inflight: token, refresh_pending?: false, refresh_timer: nil}
  end

  @doc "Records that a refresh was requested while one was already in flight."
  @spec mark_refresh_pending(t()) :: t()
  def mark_refresh_pending(%__MODULE__{} = ft), do: %{ft | refresh_pending?: true}

  @doc "Clears in-flight and pending refresh tracking once a Task result is handled."
  @spec clear_inflight_refresh(t()) :: t()
  def clear_inflight_refresh(%__MODULE__{} = ft),
    do: %{ft | refresh_inflight: nil, refresh_pending?: false}

  @doc "Marks the sidebar as failed with a displayable reason."
  @spec error(t(), term()) :: t()
  def error(%__MODULE__{} = ft, reason) do
    %{ft | focused: false, editing: nil, tree_status: {:error, format_error_reason(reason)}}
  end

  @doc "Closes the tree and clears the buffer."
  @spec close(t()) :: t()
  def close(%__MODULE__{} = ft) do
    %{
      ft
      | tree: nil,
        focused: false,
        buffer: nil,
        editing: nil,
        tree_status: :hidden,
        clipboard_mark: nil,
        filtering: false,
        help_visible: false,
        refresh_inflight: nil,
        refresh_pending?: false
    }
  end

  @doc """
  Enters inline editing mode at the given index.

  For new file/folder, `initial_text` is empty. For rename,
  `initial_text` is the current entry name.
  """
  @spec start_editing(t(), non_neg_integer(), editing_type(), String.t()) :: t()
  def start_editing(%__MODULE__{} = ft, index, type, initial_text \\ "")
      when type in [:new_file, :new_folder, :rename] and is_integer(index) and index >= 0 do
    original = if type == :rename, do: initial_text, else: nil

    %{
      ft
      | editing: %{index: index, text: initial_text, type: type, original_name: original},
        filtering: false,
        help_visible: false
    }
  end

  @doc "Updates the text being typed in the inline editor."
  @spec update_editing_text(t(), String.t()) :: t()
  def update_editing_text(%__MODULE__{editing: %{} = editing} = ft, new_text)
      when is_binary(new_text) do
    %{ft | editing: %{editing | text: new_text}}
  end

  def update_editing_text(%__MODULE__{editing: nil} = ft, _new_text), do: ft

  @doc "Stores a pending file tree clipboard operation."
  @spec mark_clipboard(t(), String.t(), String.t(), boolean(), clipboard_operation()) :: t()
  def mark_clipboard(%__MODULE__{} = ft, path, name, dir?, operation)
      when is_binary(path) and is_binary(name) and is_boolean(dir?) and
             operation in [:copy, :move] do
    %{ft | clipboard_mark: ClipboardMark.new(path, name, dir?, operation)}
  end

  @doc "Clears a pending file tree clipboard operation."
  @spec clear_clipboard(t()) :: t()
  def clear_clipboard(%__MODULE__{} = ft), do: %{ft | clipboard_mark: nil}

  @doc "Starts inline file tree filtering."
  @spec start_filtering(t()) :: t()
  def start_filtering(%__MODULE__{tree: %FileTree{} = tree} = ft) do
    filter = tree.filter || ""
    {tree, status} = filtered_tree(tree, filter)

    %{
      ft
      | tree: tree,
        tree_status: status,
        filtering: true,
        editing: nil,
        help_visible: false
    }
  end

  def start_filtering(%__MODULE__{} = ft), do: ft

  @doc """
  Updates the active file tree filter.

  When the tree root matches the active project root, the matching entries are
  filtered in memory from the project's cached file list (`Minga.Project.files/0`)
  rather than walking the filesystem. Roots not covered by the active cache fall
  back to the filesystem walk.

  While the active project's cache is still rebuilding (empty list), the tree
  reports a `:loading` pending state instead of silently re-shelling out.
  """
  @spec update_filter(t(), String.t()) :: t()
  def update_filter(%__MODULE__{tree: %FileTree{} = tree} = ft, filter) when is_binary(filter) do
    {tree, status} = filtered_tree(tree, filter)
    %{ft | tree: tree, tree_status: status}
  end

  def update_filter(%__MODULE__{} = ft, _filter), do: ft

  @doc """
  Returns true when filtering the tree requires the async no-cache filesystem
  walk (#2377 AC4): a filter is active and the tree root is not the active
  project root, so in-memory cache filtering does not cover it.
  """
  @spec needs_filter_walk?(t()) :: boolean()
  def needs_filter_walk?(%__MODULE__{tree: %FileTree{filter: filter, root: root}})
      when is_binary(filter) and filter != "" do
    not ProjectCache.active_root?(root)
  end

  def needs_filter_walk?(%__MODULE__{}), do: false

  @doc """
  Applies an async no-cache filter walk result, dropping it if stale.

  The result is keyed by the `(root, filter)` it was computed for; if the user
  has since changed the filter or re-rooted the tree it is discarded so a slow
  walk never clobbers newer state (#2377 AC4 stale-result dropping).
  """
  @spec apply_filter_walk(t(), String.t(), String.t(), [FileTree.entry()]) :: t()
  def apply_filter_walk(%__MODULE__{tree: %FileTree{} = tree} = ft, root, filter, entries) do
    if FilterWalk.fresh?(tree, root, filter) do
      tree = FileTree.put_entries(tree, entries)
      %{ft | tree: tree, tree_status: classify_entries(entries)}
    else
      ft
    end
  end

  def apply_filter_walk(%__MODULE__{} = ft, _root, _filter, _entries), do: ft

  # Resolves the filtered tree plus its presentation status. An empty filter is
  # the full unfiltered tree (always classified from the walk). With an active
  # filter, the active project root filters in memory from the cache; a
  # rebuilding (empty) cache reports `:loading`; other roots defer to an async
  # filesystem walk (`:loading` until the walk result arrives).
  @spec filtered_tree(FileTree.t(), String.t()) :: {FileTree.t(), tree_status()}
  defp filtered_tree(%FileTree{} = tree, "") do
    tree = tree |> FileTree.put_cached_files(nil) |> FileTree.set_filter("")
    {tree, classify_tree(tree)}
  end

  defp filtered_tree(%FileTree{root: root} = tree, filter) do
    if ProjectCache.active_root?(root) do
      filtered_from_cache(tree, filter, ProjectCache.files())
    else
      # No-cache root: clear the cache and mark loading; the editor spawns an
      # async walk (see needs_filter_walk?/1) and applies the result later.
      tree = tree |> FileTree.put_cached_files(nil) |> FileTree.set_filter(filter)
      {tree, :loading}
    end
  end

  @spec filtered_from_cache(FileTree.t(), String.t(), [String.t()]) ::
          {FileTree.t(), tree_status()}
  defp filtered_from_cache(tree, filter, []) do
    # Active root but the cache is empty: a rebuild is in progress (or the
    # project has no files). Show a pending state rather than re-shelling out.
    tree = tree |> FileTree.put_cached_files([]) |> FileTree.set_filter(filter)
    {tree, cache_pending_status(tree)}
  end

  defp filtered_from_cache(tree, filter, files) do
    tree = tree |> FileTree.put_cached_files(files) |> FileTree.set_filter(filter)
    {tree, classify_entries(FileTree.visible_entries(tree))}
  end

  @spec cache_pending_status(FileTree.t()) :: tree_status()
  defp cache_pending_status(tree) do
    if ProjectCache.rebuilding?(),
      do: :loading,
      else: classify_entries(FileTree.visible_entries(tree))
  end

  @doc "Accepts the current filter and leaves the narrowed tree visible."
  @spec accept_filter(t()) :: t()
  def accept_filter(%__MODULE__{} = ft), do: %{ft | filtering: false}

  @doc "Clears the active filter and exits filtering mode."
  @spec clear_filter(t()) :: t()
  def clear_filter(%__MODULE__{tree: %FileTree{} = tree} = ft) do
    # Drop the cache so non-filtered browsing resumes lazy filesystem walking.
    tree = tree |> FileTree.put_cached_files(nil) |> FileTree.clear_filter()
    %{ft | tree: tree, filtering: false, tree_status: classify_tree(tree)}
  end

  def clear_filter(%__MODULE__{} = ft), do: %{ft | filtering: false}

  @doc "Toggles the file tree help overlay."
  @spec toggle_help(t()) :: t()
  def toggle_help(%__MODULE__{} = ft),
    do: %{ft | help_visible: not ft.help_visible, filtering: false}

  @doc "Hides the file tree help overlay."
  @spec hide_help(t()) :: t()
  def hide_help(%__MODULE__{} = ft), do: %{ft | help_visible: false}

  @doc "Cancels inline editing, clearing the editing state back to nil."
  @spec cancel_editing(t()) :: t()
  def cancel_editing(%__MODULE__{} = ft) do
    %{ft | editing: nil}
  end

  @doc "Replaces the tree data."
  @spec set_tree(t(), FileTree.t() | nil) :: t()
  def set_tree(%__MODULE__{} = ft, nil), do: %{ft | tree: nil, tree_status: :hidden}
  def set_tree(%__MODULE__{} = ft, %FileTree{} = tree), do: replace_tree(ft, tree)

  @spec ensure_tree_entries(FileTree.t()) :: FileTree.t()
  defp ensure_tree_entries(%FileTree{} = tree), do: FileTree.ensure_entries(tree)

  @spec classify_tree(FileTree.t()) :: tree_status()
  defp classify_tree(%FileTree{} = tree) do
    case File.ls(tree.root) do
      {:ok, _names} -> classify_entries(FileTree.visible_entries(tree))
      {:error, reason} -> {:error, format_error_reason(reason)}
    end
  end

  @spec classify_entries([FileTree.entry()]) :: tree_status()
  defp classify_entries([]), do: :empty
  defp classify_entries(_entries), do: :ready

  @spec format_error_reason(term()) :: String.t()
  defp format_error_reason(reason) when is_atom(reason),
    do: :file.format_error(reason) |> to_string()

  defp format_error_reason(reason), do: inspect(reason)
end
