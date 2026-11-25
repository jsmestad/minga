defmodule Minga.Buffer.Provenance.Change do
  @moduledoc """
  One replacement: an edit that inserted text over a non-empty range, recorded so a later deletion can tell exactly which text it consumed. See "Record lifecycle" in `Minga.Buffer.Provenance`.

  `made` holds the locators of the runs the edit inserted (and the pieces they split into), `replaced` the runs it marked dead that can still come back. `pulls` names replacements whose consumption follows this one's although no run of theirs is in `replaced` any more, because a run that linked them was dropped; `pulled_by` is the reverse link. `owner` is the group a record keeps once its made runs are all gone.

  `made` and `replaced` follow from the runs' `made_by` and `replaced_by` fields; `pulls`, `pulled_by` and `owner` record dropped runs and cannot be recomputed from the runs.

  `Minga.Buffer.Provenance` is the only writer of changes.
  """

  alias Minga.Buffer.Provenance.Locator

  defstruct made: :gb_sets.new(),
            replaced: :gb_sets.new(),
            pulls: :gb_sets.new(),
            pulled_by: :gb_sets.new(),
            owner: :runs

  @typedoc "A change, as numbered by `Minga.Buffer.Provenance` in the order the edits were applied."
  @type id :: pos_integer()

  @typedoc """
  The group a change belongs to. `:runs` while it has made runs, whose writer says. Once they are all gone, the group of the last one, or `:permanent` when that group was discarded applied (or the text was already permanent).
  """
  @type owner :: :runs | pos_integer() | :permanent

  @type t :: %__MODULE__{
          made: :gb_sets.set(Locator.t()),
          replaced: :gb_sets.set(Locator.t()),
          pulls: :gb_sets.set(id()),
          pulled_by: :gb_sets.set(id()),
          owner: owner()
        }
end
