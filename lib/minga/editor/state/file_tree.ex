defmodule Minga.Editor.State.FileTree do
  @moduledoc """
  File tree sub-state: tree data, focus, and backing buffer.

  Wraps the three file-tree-related fields from EditorState into a
  single struct with query and mutation helpers.
  """

  alias Minga.Project.FileTree

  @typedoc "File tree sub-state."
  @type t :: %__MODULE__{
          tree: FileTree.t() | nil,
          focused: boolean(),
          buffer: pid() | nil
        }

  defstruct tree: nil,
            focused: false,
            buffer: nil

  @doc "Returns true when the file tree is open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{tree: nil}), do: false
  def open?(%__MODULE__{}), do: true

  @doc "Returns true when the file tree is open and focused."
  @spec focused?(t()) :: boolean()
  def focused?(%__MODULE__{tree: %FileTree{}, focused: true}), do: true
  def focused?(%__MODULE__{}), do: false

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
    %{ft | tree: nil, focused: false, buffer: nil}
  end
end
