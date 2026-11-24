defmodule Minga.Buffer.Author do
  @moduledoc """
  Names who made an edit, as a plain value a buffer can store and compare.

  An author is `{kind, id}`: the kind of author and its identity within that kind. Minga is `{:minga, task_id}`, where the task id is the agent session that did the work. Another kind of author, such as a collaborator in a shared session, uses the same shape with its own kind.

  An edit records an author key, `{kind, id, step}`: the author plus the step that made the edit. A step is an opaque identifier, unique within the author's task, that groups the changes one action made. For Minga it is the tool call that made the edit, or, for a published draft, the last tool call that edited the draft.

  Construct authors and keys with `minga/1` and `key/2`; pattern matching on the raw tuples is fine.
  """

  @kinds [:minga]

  @typedoc "The kind of author. Each kind names its own identity space."
  @type kind :: :minga

  @typedoc "The author's identity within its kind. For Minga, the task id."
  @type id :: String.t()

  @typedoc "An opaque identifier of one step, unique within the author's task."
  @type step :: String.t()

  @typedoc "Who made an edit."
  @type t :: {kind(), id()}

  @typedoc "Who made an edit, and in which step."
  @type key :: {kind(), id(), step()}

  @doc "Guards an author key."
  defguard is_key(value)
           when is_tuple(value) and tuple_size(value) == 3 and elem(value, 0) in @kinds and
                  is_binary(elem(value, 1)) and is_binary(elem(value, 2))

  @doc "Returns Minga, working in the task `task_id`."
  @spec minga(id()) :: t()
  def minga(task_id) when is_binary(task_id), do: {:minga, task_id}

  @doc "Returns the key an edit records when `author` makes it in `step`."
  @spec key(t(), step()) :: key()
  def key({kind, id}, step) when kind in @kinds and is_binary(id) and is_binary(step),
    do: {kind, id, step}

  @doc "Returns the author of an edit key."
  @spec author(key()) :: t()
  def author({kind, id, _step}), do: {kind, id}

  @doc "Returns the step of an edit key."
  @spec step(key()) :: step()
  def step({_kind, _id, step}), do: step
end
