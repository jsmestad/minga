defmodule Minga.Buffer.KeptReview.Observation do
  @moduledoc "Keep and commit evidence passed between the buffer and its Git worker."

  alias Minga.Buffer.Provenance
  alias Minga.Git.ReviewIdentity

  @type capture :: :unproven | {ReviewIdentity.t(), binary() | nil}
  @type transition :: {String.t() | :unborn, String.t()}
  @type origin_set :: MapSet.t(Provenance.source_key())
  @type eligibility :: [{non_neg_integer(), origin_set()}]
  @type cache_entries :: %{transition() => {eligibility(), [Provenance.keep_interval()]}}
  @type scope_key :: {String.t(), String.t(), String.t()}
  @type cache :: {scope_key(), cache_entries()} | nil
  @type result :: {:ok, [Provenance.keep_interval()], cache()} | :stale
end
