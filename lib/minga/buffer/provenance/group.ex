defmodule Minga.Buffer.Provenance.Group do
  @moduledoc """
  One unit of history: the runs one author's edit group inserted or deleted, and whether the group is applied.

  For you, a group is one undo step. For Minga, a group is one step of one task. The group keeps the locators of its runs in an ordered set, so undoing or rejecting it visits exactly those runs, in O(k log n) for k runs, without scanning the document.

  `Minga.Buffer.Provenance` is the only writer of groups.
  """

  alias Minga.Buffer.Provenance.Locator
  alias Minga.Buffer.Provenance.Run

  @enforce_keys [:author, :key]
  defstruct [:author, :key, applied: true, runs: :gb_sets.new()]

  @typedoc """
  How a group names itself to callers: Minga's author key for a Minga step, `:agent` for an agent edit with no task, and `nil` for your groups.
  """
  @type key :: Minga.Buffer.Author.key() | :agent | nil

  @type t :: %__MODULE__{
          author: Run.author(),
          key: key(),
          applied: boolean(),
          runs: :gb_sets.set(Locator.t())
        }
end
