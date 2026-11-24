defmodule MingaEditor.Agent.TaskFiles do
  @moduledoc """
  The files one Minga task has edited, in the order it last edited them: the editor's projection of the task's attributed tool edits.

  The task is named by its author (`Minga.Buffer.Author.minga/1`, `{:minga, task_id}`), the same author its edits carry into buffers (#4047). Every file a tool of the task changes moves to the end, so the last path is the file Minga is editing now. The modeline reads it to say "Minga here" when that is the file you are in, and "Minga editing retry.ex" when it is not.

  The value is pure and bounded: it keeps the most recent `max_paths/0` files.
  """

  alias Minga.Buffer.Author

  @max_paths 64

  @type t :: %__MODULE__{author: Author.t() | nil, paths: [String.t()]}

  defstruct author: nil, paths: []

  @doc "Returns an empty record for `author`, or for a task not yet known."
  @spec new(Author.t() | nil) :: t()
  def new(author \\ nil), do: %__MODULE__{author: author}

  @doc "The most files the record keeps."
  @spec max_paths() :: pos_integer()
  def max_paths, do: @max_paths

  @doc """
  Records an edit to `path` by `author`'s task.

  A different author starts a new record: the files of one task never carry over to the next.
  """
  @spec record(t(), Author.t() | nil, String.t()) :: t()
  def record(%__MODULE__{author: author} = files, author, path) when is_binary(path) do
    paths = files.paths |> List.delete(path) |> Enum.take(-(@max_paths - 1))
    %{files | paths: paths ++ [path]}
  end

  def record(%__MODULE__{}, author, path) when is_binary(path),
    do: record(new(author), author, path)

  @doc "The file the task edited last, or nil before its first edit."
  @spec current(t()) :: String.t() | nil
  def current(%__MODULE__{paths: []}), do: nil
  def current(%__MODULE__{paths: paths}), do: List.last(paths)

  @doc "Every file the task has edited, oldest first."
  @spec paths(t()) :: [String.t()]
  def paths(%__MODULE__{paths: paths}), do: paths
end
