defmodule MingaKnowledgeGraph.Score do
  @moduledoc """
  Pure familiarity scoring and decay.

  Familiarity rises with how often you open and edit a file (with
  diminishing returns) and decays toward zero the longer you go without
  touching it. A 0.0..1.0 score maps to a 0..4 heat bucket the file tree
  renders as a tint (0 = coldest/unfamiliar, 4 = warmest/familiar).

  # ponytail: open + edit counts and recency approximate "how well you know
  # this file". Real dwell time (focus duration) is a stronger signal; add it
  # if the buckets feel too coarse.
  """

  # Familiarity from inactivity halves roughly every 90 days, matching the
  # ~3-4 month implementation-detail forgetting curve.
  @half_life_days 90.0
  @open_weight 0.12
  @edit_weight 0.25
  @seconds_per_day 86_400

  @type stats :: %{
          first_seen: integer(),
          last_seen: integer(),
          open_count: non_neg_integer(),
          edit_count: non_neg_integer()
        }

  @doc """
  Familiarity in 0.0..1.0 for `stats` evaluated at `now` (unix seconds).

  Activity saturates (so the 100th edit adds little), then decays by how long
  it has been since `last_seen`.
  """
  @spec score(stats(), integer()) :: float()
  def score(stats, now) do
    activity = @open_weight * stats.open_count + @edit_weight * stats.edit_count
    saturated = 1.0 - :math.exp(-activity)
    saturated * decay(now - stats.last_seen)
  end

  @doc "Maps a 0.0..1.0 familiarity score to a 0..4 heat bucket."
  @spec level(float()) :: 0..4
  def level(score) when score < 0.10, do: 0
  def level(score) when score < 0.30, do: 1
  def level(score) when score < 0.55, do: 2
  def level(score) when score < 0.80, do: 3
  def level(_score), do: 4

  @spec decay(integer()) :: float()
  defp decay(age_seconds) when age_seconds <= 0, do: 1.0

  defp decay(age_seconds) do
    days = age_seconds / @seconds_per_day
    :math.pow(0.5, days / @half_life_days)
  end
end
