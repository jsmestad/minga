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

  @typedoc "File tree sub-state."
  @type t :: %__MODULE__{
          tree: FileTree.t() | nil,
          focused: boolean(),
          buffer: pid() | nil,
          editing: editing() | nil
        }

  defstruct tree: nil,
            focused: false,
            buffer: nil,
            editing: nil

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

  @doc "Returns the tree width, or 0 if the tree is not open."
  @spec width(t()) :: non_neg_integer()
  def width(%__MODULE__{tree: nil}), do: 0
  def width(%__MODULE__{tree: %FileTree{width: w}}), do: w

  @doc "Opens the tree with the given data, buffer, and focused state."
  @spec open(t(), FileTree.t(), pid() | nil) :: t()
  def open(%__MODULE__{} = ft, tree, buffer) do
    %{ft | tree: tree, focused: true, buffer: buffer}
  end

  @doc "Closes the tree and clears the buffer."
  @spec close(t()) :: t()
  def close(%__MODULE__{} = ft) do
    %{ft | tree: nil, focused: false, buffer: nil, editing: nil}
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
end
