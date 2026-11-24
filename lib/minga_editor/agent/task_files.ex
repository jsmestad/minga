defmodule MingaEditor.Agent.TaskFiles do
  @moduledoc """
  The files one Minga task has edited, in the order it last edited them: the editor's projection of the task's attributed tool edits.

  The task is named by its author (`Minga.Buffer.Author.minga/1`, `{:minga, task_id}`), the same author its edits carry into buffers (#4047). Every file a tool of the task changes moves to the end, so the last file is the one Minga is editing now. The modeline reads it to say "Minga here" when that is the file you are in, and "Minga editing retry.ex" when it is not.

  Each file is kept with its identity, the key `Minga.Buffer.file_identity/1` gives it, so two spellings of one file (a symlinked project root, a relative path) are one file. Reads name the task they ask about: a record made by another task answers nothing, so a new task never shows the last task's file.

  The value is pure and bounded: it keeps the most recent `max_paths/0` files.
  """

  alias Minga.Buffer.Author

  @max_paths 64

  @typedoc "A file the task edited: its identity, then the path the tool named."
  @type entry :: {identity :: String.t(), path :: String.t()}

  @typedoc "The task's author and its files, the one it edited last first."
  @type t :: %__MODULE__{author: Author.t() | nil, entries: [entry()]}

  defstruct author: nil, entries: []

  @doc "Returns an empty record for `author`, or for a task not yet known."
  @spec new(Author.t() | nil) :: t()
  def new(author \\ nil), do: %__MODULE__{author: author}

  @doc "The most files the record keeps."
  @spec max_paths() :: pos_integer()
  def max_paths, do: @max_paths

  @doc """
  Records an edit by `author`'s task to the file at `path`, whose identity is `identity`.

  A different author starts a new record: the files of one task never carry over to the next.
  """
  @spec record(t(), Author.t() | nil, String.t(), String.t()) :: t()
  def record(%__MODULE__{author: author} = files, author, path, identity)
      when is_binary(path) and is_binary(identity) do
    entries = files.entries |> List.keydelete(identity, 0) |> Enum.take(@max_paths - 1)
    %{files | entries: [{identity, path} | entries]}
  end

  def record(%__MODULE__{}, author, path, identity) when is_binary(path) and is_binary(identity),
    do: record(new(author), author, path, identity)

  @doc "The file `author`'s task edited last, as `{identity, path}`, or nil before its first edit or when the record is another task's."
  @spec current(t(), Author.t() | nil) :: entry() | nil
  def current(%__MODULE__{author: author, entries: [last | _older]}, author), do: last

  def current(%__MODULE__{}, _author), do: nil

  @doc "Every file the task has edited, oldest first, as the paths its tools named."
  @spec paths(t()) :: [String.t()]
  def paths(%__MODULE__{entries: entries}),
    do: entries |> Enum.reverse() |> Enum.map(&elem(&1, 1))
end
