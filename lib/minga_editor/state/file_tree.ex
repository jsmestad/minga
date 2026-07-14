defmodule MingaEditor.State.FileTree do
  @moduledoc """
  File tree sub-state: tree data, focus, and backing buffer.

  Wraps the file-tree-related fields from EditorState into a single
  struct with query and mutation helpers. Includes inline editing state
  for new file, new folder, and rename operations.
  """

  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.FilterWalk.Result, as: FilterResult
  alias MingaEditor.FileTree.ProjectCache.Snapshot, as: ProjectCacheSnapshot
  alias MingaEditor.State.FileTree.ClipboardMark
  alias MingaEditor.State.FileTree.Refresh
  alias MingaEditor.State.FileTree.Watchers

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

  @typedoc "Identity of the latest admitted filter request."
  @type filter_request :: %{
          root: String.t(),
          filter: String.t(),
          token: reference()
        }

  @typedoc "Explicit presentation state for the file tree sidebar."
  @type tree_status :: :hidden | :loading | :empty | :ready | {:error, String.t()}

  @typedoc "File tree sub-state."
  @type t :: %__MODULE__{
          tree: FileTree.t() | nil,
          focused: boolean(),
          hidden: boolean(),
          buffer: pid() | nil,
          editing: editing() | nil,
          project_root: String.t() | nil,
          original_root: String.t() | nil,
          tree_status: tree_status(),
          tree_width: pos_integer(),
          refresh: Refresh.t(),
          clipboard_mark: clipboard_mark() | nil,
          filtering: boolean(),
          filter_request: filter_request() | nil,
          watchers: Watchers.t(),
          help_visible: boolean()
        }

  defstruct tree: nil,
            focused: false,
            hidden: false,
            buffer: nil,
            editing: nil,
            project_root: nil,
            original_root: nil,
            tree_status: :hidden,
            tree_width: 30,
            refresh: %Refresh{},
            clipboard_mark: nil,
            filtering: false,
            filter_request: nil,
            watchers: %Watchers{},
            help_visible: false

  @doc """
  Returns true when the file tree has loaded data.

  A hidden-but-loaded tree is still loaded: the data, buffer, and watchers stay
  alive so refresh handlers keep it fresh. This is intentionally NOT "is the
  sidebar visible" — use `visible?/1` for that. Mixing the two leaks the backing
  buffer (see #2626).
  """
  @spec loaded?(t()) :: boolean()
  def loaded?(%__MODULE__{tree: nil}), do: false
  def loaded?(%__MODULE__{}), do: true

  @doc "Returns true when the sidebar is currently visible (loaded and not hidden)."
  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{} = ft), do: visible_status?(status(ft))

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

  # A loaded tree whose sidebar has been toggled off. The data and watchers stay
  # alive so showing it again is a pure layout change (#2626).
  def status(%__MODULE__{tree: %FileTree{}, hidden: true}), do: :hidden

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

  @doc """
  Hides the sidebar while keeping the loaded tree, backing buffer, and watchers.

  Toggling visibility off is a pure layout change: the render model still carries
  the full tree data so showing it again does not rebuild anything (#2626).
  """
  @spec hide(t()) :: t()
  def hide(%__MODULE__{} = ft) do
    %{ft | hidden: true, focused: false, editing: nil, filtering: false, help_visible: false}
  end

  @doc "Reveals a previously hidden tree and refocuses it."
  @spec show(t()) :: t()
  def show(%__MODULE__{} = ft), do: %{ft | hidden: false, focused: true}

  @doc "Returns the tree width, preserving the last sidebar width while state-only payloads are visible."
  @spec width(t()) :: pos_integer()
  def width(%__MODULE__{tree: nil, tree_width: width}), do: width
  def width(%__MODULE__{tree: %FileTree{width: width}}), do: width

  @doc "Opens the tree with the given data, buffer, and focused state."
  @spec open(t(), FileTree.t(), pid() | nil) :: t()
  def open(%__MODULE__{} = ft, tree, buffer) do
    watchers = Watchers.retarget(ft.watchers, current_tree_roots(ft), tree)

    %{
      ft
      | tree: tree,
        focused: true,
        hidden: false,
        buffer: buffer,
        project_root: tree.root,
        original_root: ft.original_root || tree.root,
        tree_status: classify_tree(tree),
        tree_width: tree.width,
        refresh: refresh_for_tree(ft, tree.root),
        filter_request: nil,
        watchers: watchers
    }
  end

  @doc "Replaces the backing tree and refreshes the presentation status."
  @spec replace_tree(t(), FileTree.t()) :: t()
  def replace_tree(%__MODULE__{} = ft, %FileTree{} = tree) do
    refresh = refresh_for_tree(ft, tree.root)
    watchers = Watchers.retarget(ft.watchers, current_tree_roots(ft), tree)

    %{
      ft
      | tree: tree,
        project_root: tree.root,
        tree_status: replacement_status(ft, tree),
        tree_width: tree.width,
        refresh: refresh,
        filter_request: nil,
        watchers: watchers
    }
  end

  @doc "Replaces metadata on the current tree without changing topology status or refresh correlation."
  @spec replace_tree_metadata(t(), FileTree.t()) :: t()
  def replace_tree_metadata(%__MODULE__{} = ft, %FileTree{} = tree), do: %{ft | tree: tree}

  @doc "Marks the sidebar as loading."
  @spec loading(t()) :: t()
  def loading(%__MODULE__{} = ft) do
    %{
      ft
      | focused: false,
        editing: nil,
        filtering: false,
        filter_request: nil,
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

  @doc "Publishes an immediate loading tree for a root scan without resolving entries."
  @spec begin_root_scan(t(), FileTree.t(), :project | :reroot) :: t()
  def begin_root_scan(%__MODULE__{} = ft, %FileTree{} = tree, kind)
      when kind in [:project, :reroot] do
    expanded_root = Path.expand(tree.root)
    original_root = if kind == :project, do: expanded_root, else: ft.original_root
    watchers = Watchers.retarget(ft.watchers, current_tree_roots(ft), tree)

    %{
      ft
      | tree: tree,
        project_root: expanded_root,
        original_root: original_root,
        tree_status: :loading,
        tree_width: tree.width,
        editing: nil,
        filtering: false,
        filter_request: nil,
        help_visible: false,
        refresh: Refresh.invalidate(ft.refresh),
        watchers: watchers
    }
  end

  @doc "Returns the immutable watcher intent owned by this file tree."
  @spec watcher_intent(t()) :: Watchers.t()
  def watcher_intent(%__MODULE__{} = ft), do: ft.watchers

  @doc "Correlates the latest admitted watcher synchronization request."
  @spec track_watcher_request(t(), reference()) :: t()
  def track_watcher_request(%__MODULE__{} = ft, token) when is_reference(token) do
    %{ft | watchers: Watchers.request_admitted(ft.watchers, token)}
  end

  @doc "Collapses watcher lineage only for the latest exact successful request."
  @spec accept_watcher_result(t(), reference(), String.t() | nil) :: {:current | :stale, t()}
  def accept_watcher_result(%__MODULE__{} = ft, token, target) when is_reference(token) do
    case Watchers.synchronized(ft.watchers, token, target) do
      {status, watchers} -> {status, %{ft | watchers: watchers}}
    end
  end

  @doc "Finishes watcher work without discarding cleanup candidates."
  @spec finish_watcher_request(t(), reference()) :: {:current | :stale, t()}
  def finish_watcher_request(%__MODULE__{} = ft, token) when is_reference(token) do
    case Watchers.request_finished(ft.watchers, token) do
      {status, watchers} -> {status, %{ft | watchers: watchers}}
    end
  end

  @doc "Changes the watcher target to cleanup-only while retaining all known roots."
  @spec cleanup_watchers(t()) :: t()
  def cleanup_watchers(%__MODULE__{} = ft) do
    %{ft | watchers: Watchers.cleanup(ft.watchers, current_tree_roots(ft))}
  end

  @doc "Records one debounced request to refresh the open tree."
  @spec request_refresh_debounce(t(), Refresh.debounce_token()) ::
          {:scheduled | :already_scheduled, t()}
  def request_refresh_debounce(%__MODULE__{} = ft, token) when is_reference(token) do
    {status, refresh} = Refresh.request_debounce(ft.refresh, token)
    {status, %{ft | refresh: refresh}}
  end

  @doc "Consumes a correlated debounce message and focuses the result on the live tree."
  @spec refresh_debounce_elapsed(t(), Refresh.debounce_token()) ::
          {:ready, FileTree.t(), t()} | {:closed | :stale, t()}
  def refresh_debounce_elapsed(%__MODULE__{} = ft, token) when is_reference(token) do
    case Refresh.debounce_elapsed(ft.refresh, token) do
      {:stale, refresh} ->
        {:stale, %{ft | refresh: refresh}}

      {:current, refresh} ->
        refresh_debounce_tree(%{ft | refresh: refresh})
    end
  end

  @doc "Correlates an admitted typed refresh request with the root it scans."
  @spec track_refresh_request(t(), String.t(), Refresh.request_token()) :: t()
  def track_refresh_request(%__MODULE__{} = ft, root, token)
      when is_binary(root) and is_reference(token) do
    %{ft | refresh: Refresh.request_admitted(ft.refresh, root, token)}
  end

  @doc "Re-arms one pending refresh intent after scheduler admission pressure."
  @spec track_refresh_retry(t(), Refresh.debounce_token()) :: {pos_integer(), t()}
  def track_refresh_retry(%__MODULE__{} = ft, token) when is_reference(token) do
    {attempt, refresh} = Refresh.retry_debounce(ft.refresh, token)
    {attempt, %{ft | refresh: refresh}}
  end

  @doc "Atomically accepts a current refresh result or identifies why it cannot apply."
  @spec accept_refresh_result(t(), String.t(), Refresh.request_token(), FileTree.t()) ::
          {:accepted | :closed | :rerooted | :stale, t()}
  def accept_refresh_result(%__MODULE__{} = ft, root, token, %FileTree{} = refreshed_tree)
      when is_binary(root) and is_reference(token) do
    case Refresh.request_finished(ft.refresh, root, token) do
      {:stale, refresh} ->
        {:stale, %{ft | refresh: refresh}}

      {:current, refresh} ->
        accept_current_refresh(%{ft | refresh: refresh}, root, refreshed_tree)
    end
  end

  @doc "Finishes a failed or canceled current request without changing tree content."
  @spec finish_refresh(t(), String.t(), Refresh.request_token()) ::
          {:current | :closed | :rerooted | :stale, t()}
  def finish_refresh(%__MODULE__{} = ft, root, token)
      when is_binary(root) and is_reference(token) do
    case Refresh.request_finished(ft.refresh, root, token) do
      {:stale, refresh} -> {:stale, %{ft | refresh: refresh}}
      {:current, refresh} -> classify_current_tree(%{ft | refresh: refresh}, root)
    end
  end

  @doc "Marks the sidebar as failed with a displayable reason."
  @spec error(t(), term()) :: t()
  def error(%__MODULE__{} = ft, reason) do
    %{ft | focused: false, editing: nil, tree_status: {:error, format_error_reason(reason)}}
  end

  @doc "Reports a refresh failure while preserving the open tree interaction state."
  @spec refresh_failed(t(), term()) :: t()
  def refresh_failed(%__MODULE__{} = ft, reason) do
    %{ft | tree_status: {:error, format_error_reason(reason)}}
  end

  @doc "Installs an empty failed root scan while retaining the requested root."
  @spec root_scan_failed(t(), term()) :: t()
  def root_scan_failed(%__MODULE__{tree: %FileTree{} = tree} = ft, reason) do
    ft
    |> replace_tree(FileTree.put_entries(tree, []))
    |> refresh_failed(reason)
  end

  def root_scan_failed(%__MODULE__{} = ft, reason), do: refresh_failed(ft, reason)

  @doc "Closes the tree and clears the buffer."
  @spec close(t()) :: t()
  def close(%__MODULE__{} = ft) do
    watchers = Watchers.cleanup(ft.watchers, current_tree_roots(ft))

    %{
      ft
      | tree: nil,
        focused: false,
        hidden: false,
        buffer: nil,
        editing: nil,
        tree_status: :hidden,
        clipboard_mark: nil,
        filtering: false,
        filter_request: nil,
        watchers: watchers,
        help_visible: false,
        refresh: Refresh.invalidate(ft.refresh)
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

  @doc "Starts inline file tree filtering without resolving any rows."
  @spec start_filtering(t()) :: t()
  def start_filtering(%__MODULE__{tree: %FileTree{filter: filter} = tree} = ft)
      when filter in [nil, ""] do
    %{ft | tree: FileTree.begin_filter(tree), filtering: true, editing: nil, help_visible: false}
  end

  def start_filtering(%__MODULE__{tree: %FileTree{filter: filter}} = ft)
      when is_binary(filter) and filter != "" do
    ft
    |> update_filter(filter)
    |> then(&%{&1 | filtering: true, editing: nil, help_visible: false})
  end

  def start_filtering(%__MODULE__{} = ft), do: ft

  @doc "Publishes a loading filter transition without cache or filesystem calls."
  @spec update_filter(t(), String.t()) :: t()
  def update_filter(%__MODULE__{tree: %FileTree{} = tree} = ft, filter)
      when is_binary(filter) and filter != "" do
    tree = tree |> FileTree.put_cached_files(nil) |> FileTree.set_filter(filter)
    %{ft | tree: tree, tree_status: :loading, filter_request: nil}
  end

  def update_filter(%__MODULE__{} = ft, _filter), do: ft

  @doc "Publishes an unfiltered loading tree while preserving filter-input disposition."
  @spec clear_filter_loading(t(), :keep_open | :dismiss) :: t()
  def clear_filter_loading(%__MODULE__{tree: %FileTree{} = tree} = ft, disposition) do
    tree = tree |> FileTree.put_cached_files(nil) |> FileTree.clear_filter()

    %{
      ft
      | tree: tree,
        tree_status: :loading,
        filtering: disposition == :keep_open,
        filter_request: nil
    }
  end

  def clear_filter_loading(%__MODULE__{} = ft, _disposition), do: ft

  @doc "Correlates the latest admitted filter request with its exact root and query."
  @spec track_filter_request(t(), String.t(), String.t(), reference()) :: t()
  def track_filter_request(%__MODULE__{} = ft, root, filter, token)
      when is_binary(root) and is_binary(filter) and is_reference(token) do
    request = %{root: Path.expand(root), filter: filter, token: token}
    %{ft | filter_request: request, refresh: Refresh.invalidate(ft.refresh)}
  end

  @doc "Installs a current filter result prepared by a scheduler worker."
  @spec accept_filter_result(t(), String.t(), String.t(), reference(), FilterResult.t()) ::
          {:accepted | :closed | :rerooted | :stale, t()}
  def accept_filter_result(
        %__MODULE__{} = ft,
        root,
        filter,
        token,
        %FilterResult{} = result
      )
      when is_binary(root) and is_binary(filter) and is_reference(token) do
    case classify_filter_request(ft, root, filter, token) do
      :current -> install_filter_result(%{ft | filter_request: nil}, result)
      reason -> {reason, ft}
    end
  end

  @doc "Finishes a current failed or canceled filter request without installing rows."
  @spec finish_filter(t(), String.t(), String.t(), reference()) ::
          {:current | :closed | :rerooted | :stale, t()}
  def finish_filter(%__MODULE__{} = ft, root, filter, token)
      when is_binary(root) and is_binary(filter) and is_reference(token) do
    case classify_filter_request(ft, root, filter, token) do
      :current -> {:current, %{ft | filter_request: nil}}
      reason -> {reason, ft}
    end
  end

  @doc "Reports a current filter failure while preserving recovery on the next query."
  @spec filter_failed(t(), term()) :: t()
  def filter_failed(%__MODULE__{} = ft, reason), do: refresh_failed(ft, reason)

  @doc "Accepts the current filter and leaves the narrowed tree visible."
  @spec accept_filter(t()) :: t()
  def accept_filter(%__MODULE__{} = ft), do: %{ft | filtering: false}

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
  def set_tree(%__MODULE__{} = ft, nil) do
    %{
      ft
      | tree: nil,
        tree_status: :hidden,
        refresh: Refresh.invalidate(ft.refresh),
        filter_request: nil,
        watchers: Watchers.cleanup(ft.watchers, current_tree_roots(ft))
    }
  end

  def set_tree(%__MODULE__{} = ft, %FileTree{} = tree), do: replace_tree(ft, tree)

  @spec refresh_debounce_tree(t()) :: {:ready, FileTree.t(), t()} | {:closed, t()}
  defp refresh_debounce_tree(%__MODULE__{tree: %FileTree{} = tree} = ft), do: {:ready, tree, ft}
  defp refresh_debounce_tree(%__MODULE__{} = ft), do: {:closed, ft}

  @spec accept_current_refresh(t(), String.t(), FileTree.t()) ::
          {:accepted | :closed | :rerooted | :stale, t()}
  defp accept_current_refresh(%__MODULE__{tree: nil} = ft, _root, _tree), do: {:closed, ft}

  defp accept_current_refresh(
         %__MODULE__{
           tree: %FileTree{root: live_root},
           project_root: project_root,
           filter_request: filter_request
         } = ft,
         root,
         %FileTree{root: result_root} = refreshed_tree
       ) do
    expanded_root = Path.expand(root)

    case {Path.expand(live_root) == expanded_root,
          is_binary(project_root) and Path.expand(project_root) == expanded_root,
          Path.expand(result_root) == expanded_root, is_nil(filter_request)} do
      {false, _project_matches?, _result_matches?, _filter_idle?} -> {:rerooted, ft}
      {true, false, _result_matches?, _filter_idle?} -> {:rerooted, ft}
      {true, true, false, _filter_idle?} -> {:stale, ft}
      {true, true, true, false} -> {:stale, ft}
      {true, true, true, true} -> {:accepted, replace_tree(ft, refreshed_tree)}
    end
  end

  @spec classify_current_tree(t(), String.t()) :: {:current | :closed | :rerooted, t()}
  defp classify_current_tree(%__MODULE__{tree: nil} = ft, _root), do: {:closed, ft}

  defp classify_current_tree(
         %__MODULE__{tree: %FileTree{root: live_root}, project_root: project_root} = ft,
         root
       ) do
    expanded_root = Path.expand(root)

    if Path.expand(live_root) == expanded_root and is_binary(project_root) and
         Path.expand(project_root) == expanded_root do
      {:current, ft}
    else
      {:rerooted, ft}
    end
  end

  @spec classify_filter_request(t(), String.t(), String.t(), reference()) ::
          :current | :closed | :rerooted | :stale
  defp classify_filter_request(%__MODULE__{tree: nil}, _root, _filter, _token), do: :closed

  defp classify_filter_request(
         %__MODULE__{
           tree: %FileTree{root: live_root, filter: live_filter},
           project_root: project_root,
           filter_request: request
         },
         root,
         filter,
         token
       ) do
    expanded_root = Path.expand(root)

    case request do
      %{root: ^expanded_root, filter: ^filter, token: ^token} ->
        if Path.expand(live_root) == expanded_root and live_filter == filter and
             is_binary(project_root) and Path.expand(project_root) == expanded_root do
          :current
        else
          :rerooted
        end

      _request ->
        :stale
    end
  end

  @spec install_filter_result(t(), FilterResult.t()) ::
          {:accepted | :stale, t()}
  defp install_filter_result(
         %__MODULE__{tree: %FileTree{} = tree} = ft,
         %FilterResult{root: root, filter: filter, source: :filesystem, entries: entries}
       )
       when is_list(entries) do
    if Path.expand(tree.root) == Path.expand(root) and tree.filter == filter do
      tree = FileTree.put_entries(tree, entries)
      watchers = Watchers.retarget(ft.watchers, [tree.root], tree)
      {:accepted, %{ft | tree: tree, tree_status: classify_entries(entries), watchers: watchers}}
    else
      {:stale, ft}
    end
  end

  defp install_filter_result(
         %__MODULE__{tree: %FileTree{} = tree} = ft,
         %FilterResult{
           root: root,
           filter: filter,
           source: :project_cache,
           entries: entries,
           project_cache: %ProjectCacheSnapshot{} = snapshot
         }
       )
       when is_list(entries) do
    if Path.expand(tree.root) == Path.expand(root) and tree.filter == filter and
         snapshot.active? and Path.expand(snapshot.root) == Path.expand(root) do
      tree = tree |> FileTree.put_cached_files(snapshot.files) |> FileTree.put_entries(entries)
      status = cache_result_status(entries, snapshot)
      watchers = Watchers.retarget(ft.watchers, [tree.root], tree)
      {:accepted, %{ft | tree: tree, tree_status: status, watchers: watchers}}
    else
      {:stale, ft}
    end
  end

  @spec cache_result_status([FileTree.entry()], ProjectCacheSnapshot.t()) :: tree_status()
  defp cache_result_status(_entries, %ProjectCacheSnapshot{files: [], rebuilding?: true}),
    do: :loading

  defp cache_result_status(entries, %ProjectCacheSnapshot{}), do: classify_entries(entries)

  @spec current_tree_roots(t()) :: [String.t()]
  defp current_tree_roots(%__MODULE__{tree: %FileTree{root: root}}), do: [root]
  defp current_tree_roots(%__MODULE__{}), do: []

  @spec refresh_for_tree(t(), String.t()) :: Refresh.t()
  defp refresh_for_tree(
         %__MODULE__{tree: %FileTree{root: root}, refresh: refresh},
         root
       ),
       do: refresh

  defp refresh_for_tree(%__MODULE__{refresh: refresh}, _root), do: Refresh.invalidate(refresh)

  @spec replacement_status(t(), FileTree.t()) :: tree_status()
  defp replacement_status(%__MODULE__{tree: %FileTree{}, tree_status: status}, %FileTree{
         entries: nil
       }),
       do: status

  defp replacement_status(%__MODULE__{}, %FileTree{} = tree), do: classify_tree(tree)

  @spec classify_tree(FileTree.t()) :: tree_status()
  defp classify_tree(%FileTree{entries: nil}), do: :loading
  defp classify_tree(%FileTree{entries: entries}), do: classify_entries(entries)

  @spec classify_entries([FileTree.entry()]) :: tree_status()
  defp classify_entries([]), do: :empty
  defp classify_entries(_entries), do: :ready

  @spec format_error_reason(term()) :: String.t()
  defp format_error_reason(reason) when is_atom(reason),
    do: :file.format_error(reason) |> to_string()

  defp format_error_reason(reason), do: inspect(reason)
end
