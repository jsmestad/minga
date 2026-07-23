defmodule MingaEditor.State.FileTree do
  @moduledoc """
  File tree sub-state: tree data, focus, and backing buffer.

  Wraps the file-tree-related fields from EditorState into a single
  struct with query and transition helpers. Includes inline editing state
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

  Present while `interaction` is `{:editing, editing()}`. The `editing/1`
  query returns `nil` in every other interaction phase.
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

  @typedoc "Derived presentation state for the file tree sidebar."
  @type status :: :hidden | :loading | :empty | :ready | {:error, String.t()}

  @typedoc "Single owner tag for resident file-tree content."
  @type content ::
          :closed
          | {:loading, FileTree.t() | nil}
          | {:ready, FileTree.t()}
          | {:error, String.t(), FileTree.t() | nil}

  @typedoc "Explicit visibility phase for the file tree sidebar."
  @type visibility :: :hidden | :visible | :focused

  @typedoc "Explicit user interaction phase for the file tree sidebar."
  @type interaction :: :browse | {:editing, editing()} | :filtering | :help

  @typedoc "File tree sub-state."
  @type t :: %__MODULE__{
          content: content(),
          visibility: visibility(),
          buffer: pid() | nil,
          interaction: interaction(),
          project_root: String.t() | nil,
          original_root: String.t() | nil,
          tree_width: pos_integer(),
          refresh: Refresh.t(),
          clipboard_mark: clipboard_mark() | nil,
          filter_request: filter_request() | nil,
          watchers: Watchers.t()
        }

  defstruct content: :closed,
            visibility: :hidden,
            buffer: nil,
            interaction: :browse,
            project_root: nil,
            original_root: nil,
            tree_width: 30,
            refresh: %Refresh{},
            clipboard_mark: nil,
            filter_request: nil,
            watchers: %Watchers{}

  @spec content(t()) :: content()
  def content(%__MODULE__{content: content}), do: content

  @spec tree(t()) :: FileTree.t() | nil
  def tree(%__MODULE__{content: {:loading, tree}}), do: tree
  def tree(%__MODULE__{content: {:ready, %FileTree{} = tree}}), do: tree
  def tree(%__MODULE__{content: {:error, _reason, tree}}), do: tree
  def tree(%__MODULE__{}), do: nil

  @doc """
  Returns true when the file tree has loaded data.

  A hidden-but-loaded tree is still loaded: the data, buffer, and watchers stay
  alive so refresh handlers keep it fresh. This is intentionally NOT "is the
  sidebar visible" — use `visible?/1` for that. Mixing the two leaks the backing
  buffer (see #2626).
  """
  @spec loaded?(t()) :: boolean()
  def loaded?(%__MODULE__{} = ft), do: match?(%FileTree{}, tree(ft))

  @spec visible?(t()) :: boolean()
  def visible?(%__MODULE__{visibility: visibility}), do: visibility != :hidden

  @spec focused?(t()) :: boolean()
  def focused?(%__MODULE__{visibility: :focused} = ft), do: match?(%FileTree{}, tree(ft))
  def focused?(%__MODULE__{}), do: false

  @spec editing?(t()) :: boolean()
  def editing?(%__MODULE__{} = ft), do: editing(ft) != nil

  @spec editing(t()) :: editing() | nil
  def editing(%__MODULE__{interaction: {:editing, editing}}), do: editing
  def editing(%__MODULE__{}), do: nil

  @spec status(t()) :: status()
  def status(%__MODULE__{visibility: :hidden, content: {:loading, %FileTree{}}}), do: :hidden
  def status(%__MODULE__{visibility: :hidden, content: {:ready, %FileTree{}}}), do: :hidden

  def status(%__MODULE__{visibility: :hidden, content: {:error, _reason, %FileTree{}}}),
    do: :hidden

  def status(%__MODULE__{content: :closed}), do: :hidden
  def status(%__MODULE__{content: {:loading, _tree}}), do: :loading
  def status(%__MODULE__{content: {:error, reason, _tree}}), do: {:error, reason}
  def status(%__MODULE__{content: {:ready, %FileTree{} = tree}}), do: classify_tree(tree)

  @spec visible_status?(status()) :: boolean()
  def visible_status?(:hidden), do: false
  def visible_status?(_status), do: true

  @doc "Marks the visible file tree as focused."
  @spec focus(t()) :: t()
  def focus(%__MODULE__{visibility: :visible} = ft), do: %{ft | visibility: :focused}
  def focus(%__MODULE__{} = ft), do: ft

  @doc "Marks the file tree as unfocused."
  @spec unfocus(t()) :: t()
  def unfocus(%__MODULE__{visibility: :focused} = ft), do: %{ft | visibility: :visible}
  def unfocus(%__MODULE__{} = ft), do: ft

  @doc """
  Hides the sidebar while keeping the loaded tree, backing buffer, and watchers.

  Toggling visibility off is a pure layout change: the render model still carries
  the full tree data so showing it again does not rebuild anything (#2626).
  """
  @spec hide(t()) :: t()
  def hide(%__MODULE__{} = ft), do: %{ft | visibility: :hidden, interaction: :browse}

  @spec show(t()) :: t()
  def show(%__MODULE__{} = ft), do: %{ft | visibility: :focused}

  @spec width(t()) :: pos_integer()
  def width(%__MODULE__{} = ft) do
    case tree(ft) do
      %FileTree{width: width} -> width
      nil -> ft.tree_width
    end
  end

  @spec open(t(), FileTree.t(), pid() | nil) :: t()
  def open(%__MODULE__{} = ft, tree, buffer) do
    watchers = Watchers.retarget(ft.watchers, current_tree_roots(ft), tree)

    %{
      ft
      | content: content_for_tree(tree),
        visibility: :focused,
        buffer: buffer,
        interaction: :browse,
        project_root: tree.root,
        original_root: ft.original_root || tree.root,
        tree_width: tree.width,
        refresh: refresh_for_tree(ft, tree.root),
        filter_request: nil,
        watchers: watchers
    }
  end

  @spec replace_tree(t(), FileTree.t()) :: t()
  def replace_tree(%__MODULE__{} = ft, %FileTree{} = tree) do
    refresh = refresh_for_tree(ft, tree.root)
    watchers = Watchers.retarget(ft.watchers, current_tree_roots(ft), tree)

    %{
      ft
      | content: replacement_content(ft, tree),
        project_root: tree.root,
        tree_width: tree.width,
        refresh: refresh,
        filter_request: nil,
        watchers: watchers
    }
  end

  @doc "Replaces metadata on the current tree without changing topology status or refresh correlation."
  @spec replace_tree_metadata(t(), FileTree.t()) :: t()
  def replace_tree_metadata(%__MODULE__{} = ft, %FileTree{} = tree),
    do: put_content_tree(ft, tree)

  @doc "Marks the sidebar as loading."
  @spec loading(t()) :: t()
  def loading(%__MODULE__{} = ft) do
    %{
      ft
      | content: {:loading, tree(ft)},
        visibility: :visible,
        interaction: :browse,
        filter_request: nil
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
      | content: {:loading, tree},
        project_root: expanded_root,
        original_root: original_root,
        tree_width: tree.width,
        interaction: :browse,
        filter_request: nil,
        refresh: Refresh.invalidate(ft.refresh),
        watchers: watchers
    }
  end

  @doc "Returns the immutable watcher intent owned by this file tree."
  @spec watcher_intent(t()) :: Watchers.t()
  def watcher_intent(%__MODULE__{} = ft), do: ft.watchers

  @doc "Returns the monotonic generation of the current root and watcher lineage."
  @spec root_generation(t()) :: non_neg_integer()
  def root_generation(%__MODULE__{} = ft), do: ft.watchers.generation

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

  @doc "Correlates a bounded watcher synchronization retry."
  @spec schedule_watcher_retry(t(), reference()) :: {pos_integer(), t()}
  def schedule_watcher_retry(%__MODULE__{} = ft, token) when is_reference(token) do
    {attempt, watchers} = Watchers.retry_scheduled(ft.watchers, token)
    {attempt, %{ft | watchers: watchers}}
  end

  @doc "Consumes only the current watcher retry timer."
  @spec watcher_retry_elapsed(t(), reference()) :: {:current | :stale, t()}
  def watcher_retry_elapsed(%__MODULE__{} = ft, token) when is_reference(token) do
    case Watchers.retry_elapsed(ft.watchers, token) do
      {status, watchers} -> {status, %{ft | watchers: watchers}}
    end
  end

  @doc "Terminalizes watcher retry correlation after the bounded attempt budget."
  @spec exhaust_watcher_retry(t()) :: t()
  def exhaust_watcher_retry(%__MODULE__{} = ft) do
    %{ft | watchers: Watchers.retry_exhausted(ft.watchers)}
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
    %{
      ft
      | content: {:error, format_error_reason(reason), tree(ft)},
        visibility: :visible,
        interaction: :browse
    }
  end

  @doc "Reports a refresh failure while preserving the open tree interaction state."
  @spec refresh_failed(t(), term()) :: t()
  def refresh_failed(%__MODULE__{} = ft, reason) do
    %{ft | content: {:error, format_error_reason(reason), tree(ft)}}
  end

  @doc "Installs an empty failed root scan while retaining the requested root."
  @spec root_scan_failed(t(), term()) :: t()
  def root_scan_failed(%__MODULE__{} = ft, reason) do
    file_tree =
      case tree(ft) do
        %FileTree{} = tree -> put_content_tree(ft, FileTree.put_entries(tree, []))
        nil -> ft
      end

    refresh_failed(file_tree, reason)
  end

  @doc "Closes the tree and clears the buffer."
  @spec close(t()) :: t()
  def close(%__MODULE__{} = ft) do
    watchers = Watchers.cleanup(ft.watchers, current_tree_roots(ft))

    %{
      ft
      | content: :closed,
        visibility: :hidden,
        buffer: nil,
        interaction: :browse,
        clipboard_mark: nil,
        filter_request: nil,
        watchers: watchers,
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
      | interaction:
          {:editing, %{index: index, text: initial_text, type: type, original_name: original}}
    }
  end

  @doc "Updates the text being typed in the inline editor."
  @spec update_editing_text(t(), String.t()) :: t()
  def update_editing_text(%__MODULE__{interaction: {:editing, editing}} = ft, new_text)
      when is_binary(new_text) do
    %{ft | interaction: {:editing, %{editing | text: new_text}}}
  end

  def update_editing_text(%__MODULE__{} = ft, _new_text), do: ft

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
  def start_filtering(%__MODULE__{} = ft) do
    case tree(ft) do
      %FileTree{filter: filter} = tree when filter in [nil, ""] ->
        ft
        |> put_content_tree(FileTree.begin_filter(tree))
        |> then(&%{&1 | interaction: :filtering})

      %FileTree{filter: filter} when is_binary(filter) and filter != "" ->
        ft
        |> update_filter(filter)
        |> then(&%{&1 | interaction: :filtering})

      nil ->
        ft
    end
  end

  @doc "Publishes a loading filter transition without cache or filesystem calls."
  @spec update_filter(t(), String.t()) :: t()
  def update_filter(%__MODULE__{} = ft, filter) when is_binary(filter) and filter != "" do
    case tree(ft) do
      %FileTree{} = tree ->
        tree = tree |> FileTree.put_cached_files(nil) |> FileTree.set_filter(filter)
        %{ft | content: {:loading, tree}, filter_request: nil}

      nil ->
        ft
    end
  end

  def update_filter(%__MODULE__{} = ft, _filter), do: ft

  @doc "Publishes an unfiltered loading tree while preserving filter-input disposition."
  @spec clear_filter_loading(t(), :keep_open | :dismiss) :: t()
  def clear_filter_loading(%__MODULE__{} = ft, disposition) do
    case tree(ft) do
      %FileTree{} = tree ->
        tree = tree |> FileTree.put_cached_files(nil) |> FileTree.clear_filter()

        %{
          ft
          | content: {:loading, tree},
            interaction: if(disposition == :keep_open, do: :filtering, else: :browse),
            filter_request: nil
        }

      nil ->
        ft
    end
  end

  @doc "Correlates the latest admitted filter request with its exact root and query."
  @spec track_filter_request(t(), String.t(), String.t(), reference()) :: t()
  def track_filter_request(%__MODULE__{} = ft, root, filter, token)
      when is_binary(root) and is_binary(filter) and is_reference(token) do
    expanded_root = Path.expand(root)

    case tree(ft) do
      %FileTree{root: live_root, filter: live_filter} ->
        if Path.expand(live_root) == expanded_root and live_filter == filter and
             is_binary(ft.project_root) and Path.expand(ft.project_root) == expanded_root do
          request = %{root: expanded_root, filter: filter, token: token}
          %{ft | filter_request: request, refresh: Refresh.invalidate(ft.refresh)}
        else
          ft
        end

      _tree ->
        ft
    end
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
  def accept_filter(%__MODULE__{interaction: :filtering} = ft), do: %{ft | interaction: :browse}
  def accept_filter(%__MODULE__{} = ft), do: ft

  @doc "Toggles the file tree help overlay."
  @spec toggle_help(t()) :: t()
  def toggle_help(%__MODULE__{interaction: :browse} = ft), do: %{ft | interaction: :help}
  def toggle_help(%__MODULE__{interaction: :help} = ft), do: %{ft | interaction: :browse}
  def toggle_help(%__MODULE__{interaction: :filtering} = ft), do: %{ft | interaction: :help}
  def toggle_help(%__MODULE__{} = ft), do: ft

  @doc "Hides the file tree help overlay."
  @spec hide_help(t()) :: t()
  def hide_help(%__MODULE__{interaction: :help} = ft), do: %{ft | interaction: :browse}
  def hide_help(%__MODULE__{} = ft), do: ft

  @doc "Cancels inline editing, clearing the editing state back to browse."
  @spec cancel_editing(t()) :: t()
  def cancel_editing(%__MODULE__{interaction: {:editing, _}} = ft),
    do: %{ft | interaction: :browse}

  def cancel_editing(%__MODULE__{} = ft), do: ft

  @doc "Replaces the tree data."
  @spec set_tree(t(), FileTree.t() | nil) :: t()
  def set_tree(%__MODULE__{} = ft, nil), do: close(ft)
  def set_tree(%__MODULE__{} = ft, %FileTree{} = tree), do: replace_tree(ft, tree)

  @spec refresh_debounce_tree(t()) :: {:ready, FileTree.t(), t()} | {:closed, t()}
  defp refresh_debounce_tree(%__MODULE__{} = ft) do
    case tree(ft) do
      %FileTree{} = tree -> {:ready, tree, ft}
      nil -> {:closed, ft}
    end
  end

  @spec accept_current_refresh(t(), String.t(), FileTree.t()) ::
          {:accepted | :closed | :rerooted | :stale, t()}
  defp accept_current_refresh(
         %__MODULE__{} = ft,
         root,
         %FileTree{root: result_root} = refreshed_tree
       ) do
    expanded_root = Path.expand(root)

    case tree(ft) do
      nil ->
        {:closed, ft}

      %FileTree{root: live_root} ->
        case {Path.expand(live_root) == expanded_root,
              is_binary(ft.project_root) and Path.expand(ft.project_root) == expanded_root,
              Path.expand(result_root) == expanded_root, is_nil(ft.filter_request)} do
          {false, _project_matches?, _result_matches?, _filter_idle?} -> {:rerooted, ft}
          {true, false, _result_matches?, _filter_idle?} -> {:rerooted, ft}
          {true, true, false, _filter_idle?} -> {:stale, ft}
          {true, true, true, false} -> {:stale, ft}
          {true, true, true, true} -> {:accepted, replace_tree(ft, refreshed_tree)}
        end
    end
  end

  @spec classify_current_tree(t(), String.t()) :: {:current | :closed | :rerooted, t()}
  defp classify_current_tree(%__MODULE__{} = ft, root) do
    expanded_root = Path.expand(root)

    case tree(ft) do
      nil ->
        {:closed, ft}

      %FileTree{root: live_root} ->
        if Path.expand(live_root) == expanded_root and is_binary(ft.project_root) and
             Path.expand(ft.project_root) == expanded_root do
          {:current, ft}
        else
          {:rerooted, ft}
        end
    end
  end

  @spec classify_filter_request(t(), String.t(), String.t(), reference()) ::
          :current | :closed | :rerooted | :stale
  defp classify_filter_request(%__MODULE__{} = ft, root, filter, token) do
    expanded_root = Path.expand(root)

    case {tree(ft), ft.filter_request} do
      {nil, _request} ->
        :closed

      {%FileTree{root: live_root, filter: live_filter},
       %{root: ^expanded_root, filter: ^filter, token: ^token}} ->
        if Path.expand(live_root) == expanded_root and live_filter == filter and
             is_binary(ft.project_root) and Path.expand(ft.project_root) == expanded_root do
          :current
        else
          :rerooted
        end

      {_tree, _request} ->
        :stale
    end
  end

  @spec install_filter_result(t(), FilterResult.t()) ::
          {:accepted | :stale, t()}
  defp install_filter_result(
         %__MODULE__{} = ft,
         %FilterResult{root: root, filter: filter, source: :filesystem, entries: entries}
       )
       when is_list(entries) do
    case tree(ft) do
      %FileTree{} = tree ->
        if Path.expand(tree.root) == Path.expand(root) and tree.filter == filter do
          tree = FileTree.put_entries(tree, entries)
          watchers = Watchers.retarget(ft.watchers, [tree.root], tree)
          {:accepted, %{ft | content: {:ready, tree}, watchers: watchers}}
        else
          {:stale, ft}
        end

      _tree ->
        {:stale, ft}
    end
  end

  defp install_filter_result(
         %__MODULE__{} = ft,
         %FilterResult{
           root: root,
           filter: filter,
           source: :project_cache,
           entries: entries,
           project_cache: %ProjectCacheSnapshot{} = snapshot
         }
       )
       when is_list(entries) do
    case tree(ft) do
      %FileTree{} = tree ->
        if Path.expand(tree.root) == Path.expand(root) and tree.filter == filter and
             snapshot.active? and Path.expand(snapshot.root) == Path.expand(root) do
          tree =
            tree |> FileTree.put_cached_files(snapshot.files) |> FileTree.put_entries(entries)

          content = cache_result_content(tree, snapshot)
          watchers = Watchers.retarget(ft.watchers, [tree.root], tree)
          {:accepted, %{ft | content: content, watchers: watchers}}
        else
          {:stale, ft}
        end

      _tree ->
        {:stale, ft}
    end
  end

  @spec cache_result_content(FileTree.t(), ProjectCacheSnapshot.t()) :: content()
  defp cache_result_content(%FileTree{} = tree, %ProjectCacheSnapshot{
         files: [],
         rebuilding?: true
       }),
       do: {:loading, tree}

  defp cache_result_content(%FileTree{} = tree, %ProjectCacheSnapshot{}), do: {:ready, tree}

  @spec current_tree_roots(t()) :: [String.t()]
  defp current_tree_roots(%__MODULE__{} = ft) do
    case tree(ft) do
      %FileTree{root: root} -> [root]
      nil -> []
    end
  end

  @spec refresh_for_tree(t(), String.t()) :: Refresh.t()
  defp refresh_for_tree(%__MODULE__{} = ft, root) do
    case tree(ft) do
      %FileTree{root: ^root} -> ft.refresh
      _tree -> Refresh.invalidate(ft.refresh)
    end
  end

  @spec replacement_content(t(), FileTree.t()) :: content()
  defp replacement_content(
         %__MODULE__{content: {:loading, _tree}},
         %FileTree{entries: nil} = tree
       ),
       do: {:loading, tree}

  defp replacement_content(
         %__MODULE__{content: {:error, reason, _tree}},
         %FileTree{entries: nil} = tree
       ),
       do: {:error, reason, tree}

  defp replacement_content(%__MODULE__{content: {:ready, _tree}}, %FileTree{} = tree),
    do: {:ready, tree}

  defp replacement_content(%__MODULE__{}, %FileTree{} = tree), do: content_for_tree(tree)

  @spec content_for_tree(FileTree.t()) :: content()
  defp content_for_tree(%FileTree{entries: nil} = tree), do: {:loading, tree}
  defp content_for_tree(%FileTree{} = tree), do: {:ready, tree}

  @spec put_content_tree(t(), FileTree.t()) :: t()
  defp put_content_tree(%__MODULE__{} = ft, %FileTree{} = tree) do
    content =
      case ft.content do
        {:loading, _tree} -> {:loading, tree}
        {:ready, _tree} -> {:ready, tree}
        {:error, reason, _tree} -> {:error, reason, tree}
        :closed -> content_for_tree(tree)
      end

    %{ft | content: content, tree_width: tree.width}
  end

  @spec classify_tree(FileTree.t()) :: status()
  defp classify_tree(%FileTree{entries: nil}), do: :ready
  defp classify_tree(%FileTree{entries: entries}), do: classify_entries(entries)

  @spec classify_entries([FileTree.entry()]) :: status()
  defp classify_entries([]), do: :empty
  defp classify_entries(_entries), do: :ready

  @spec format_error_reason(term()) :: String.t()
  defp format_error_reason(reason) when is_atom(reason),
    do: :file.format_error(reason) |> to_string()

  defp format_error_reason(reason), do: inspect(reason)
end
