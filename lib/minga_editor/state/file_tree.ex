defmodule MingaEditor.State.FileTree do
  @moduledoc """
  File tree sub-state: tree data, focus, and backing buffer.

  Wraps the file-tree-related fields from EditorState into a single
  struct with query and mutation helpers. Includes inline editing state
  for new file, new folder, and rename operations.
  """

  alias Minga.Project.FileTree

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

  @typedoc "Explicit presentation state for the file tree sidebar."
  @type tree_status :: :hidden | :loading | :empty | :ready | {:error, String.t()}

  @typedoc "File tree sub-state."
  @type t :: %__MODULE__{
          tree: FileTree.t() | nil,
          focused: boolean(),
          buffer: pid() | nil,
          editing: editing() | nil,
          project_root: String.t() | nil,
          tree_status: tree_status(),
          tree_width: pos_integer()
        }

  defstruct tree: nil,
            focused: false,
            buffer: nil,
            editing: nil,
            project_root: nil,
            tree_status: :hidden,
            tree_width: 30

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
  def status(%__MODULE__{tree_status: :loading}), do: :loading
  def status(%__MODULE__{tree_status: {:error, _reason} = status}), do: status
  def status(%__MODULE__{tree: %FileTree{} = tree}), do: classify_tree(tree)

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
    %{
      ft
      | tree: tree,
        focused: true,
        buffer: buffer,
        tree_status: classify_tree(tree),
        tree_width: tree.width
    }
  end

  @doc "Replaces the backing tree and refreshes the presentation status."
  @spec replace_tree(t(), FileTree.t()) :: t()
  def replace_tree(%__MODULE__{} = ft, %FileTree{} = tree) do
    %{ft | tree: tree, tree_status: classify_tree(tree), tree_width: tree.width}
  end

  @doc "Marks the sidebar as loading."
  @spec loading(t()) :: t()
  def loading(%__MODULE__{} = ft) do
    %{ft | focused: false, editing: nil, tree_status: :loading}
  end

  @doc "Marks the sidebar as failed with a displayable reason."
  @spec error(t(), term()) :: t()
  def error(%__MODULE__{} = ft, reason) do
    %{ft | focused: false, editing: nil, tree_status: {:error, format_error_reason(reason)}}
  end

  @doc "Closes the tree and clears the buffer."
  @spec close(t()) :: t()
  def close(%__MODULE__{} = ft) do
    %{ft | tree: nil, focused: false, buffer: nil, editing: nil, tree_status: :hidden}
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

    %{ft | editing: %{index: index, text: initial_text, type: type, original_name: original}}
  end

  @doc "Updates the text being typed in the inline editor."
  @spec update_editing_text(t(), String.t()) :: t()
  def update_editing_text(%__MODULE__{editing: %{} = editing} = ft, new_text)
      when is_binary(new_text) do
    %{ft | editing: %{editing | text: new_text}}
  end

  def update_editing_text(%__MODULE__{editing: nil} = ft, _new_text), do: ft

  @doc "Cancels inline editing, clearing the editing state back to nil."
  @spec cancel_editing(t()) :: t()
  def cancel_editing(%__MODULE__{} = ft) do
    %{ft | editing: nil}
  end

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
