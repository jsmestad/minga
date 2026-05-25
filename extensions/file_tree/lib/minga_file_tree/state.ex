defmodule MingaFileTree.State do
  @moduledoc """
  File tree sub-state: tree data, focus, and backing buffer.

  Wraps the file-tree-related fields from EditorState into a single
  struct with query and mutation helpers. Includes inline editing state
  for new file, new folder, and rename operations.
  """

  alias Minga.Project.FileTree
  alias MingaFileTree.State.ClipboardMark

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
            clipboard_mark: nil,
            filtering: false,
            help_visible: false

  @doc "Coerces legacy or opaque maps from host state into FileTree state."
  @spec coerce(t() | map() | nil) :: t()
  def coerce(%__MODULE__{} = ft), do: ft

  def coerce(nil), do: %__MODULE__{}

  def coerce(value) when is_map(value) do
    %__MODULE__{
      tree: Map.get(value, :tree),
      focused: Map.get(value, :focused, false),
      buffer: Map.get(value, :buffer),
      editing: Map.get(value, :editing),
      project_root: Map.get(value, :project_root),
      original_root: Map.get(value, :original_root),
      tree_status: Map.get(value, :tree_status, :hidden),
      tree_width: Map.get(value, :tree_width) || tree_width_from(Map.get(value, :tree)),
      refresh_timer: Map.get(value, :refresh_timer),
      clipboard_mark: Map.get(value, :clipboard_mark),
      filtering: Map.get(value, :filtering, false),
      help_visible: Map.get(value, :help_visible, false)
    }
  end

  @spec tree_width_from(FileTree.t() | nil | term()) :: pos_integer()
  defp tree_width_from(%FileTree{width: width}), do: width
  defp tree_width_from(_tree), do: 30

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
        help_visible: false
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

    %{
      ft
      | tree: FileTree.set_filter(tree, filter),
        filtering: true,
        editing: nil,
        help_visible: false
    }
  end

  def start_filtering(%__MODULE__{} = ft), do: ft

  @doc "Updates the active file tree filter."
  @spec update_filter(t(), String.t()) :: t()
  def update_filter(%__MODULE__{tree: %FileTree{} = tree} = ft, filter) when is_binary(filter) do
    tree = FileTree.set_filter(tree, filter)
    %{ft | tree: tree, tree_status: classify_tree(tree)}
  end

  def update_filter(%__MODULE__{} = ft, _filter), do: ft

  @doc "Accepts the current filter and leaves the narrowed tree visible."
  @spec accept_filter(t()) :: t()
  def accept_filter(%__MODULE__{} = ft), do: %{ft | filtering: false}

  @doc "Clears the active filter and exits filtering mode."
  @spec clear_filter(t()) :: t()
  def clear_filter(%__MODULE__{tree: %FileTree{} = tree} = ft) do
    tree = FileTree.clear_filter(tree)
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
