defmodule MingaKnowledgeGraph.ScoreTest do
  use ExUnit.Case, async: true

  alias MingaKnowledgeGraph.Score

  @day 86_400

  defp stats(opens, edits, last_seen),
    do: %{first_seen: 0, last_seen: last_seen, open_count: opens, edit_count: edits}

  test "more activity yields a higher score" do
    now = 1_000_000
    light = Score.score(stats(1, 0, now), now)
    heavy = Score.score(stats(10, 20, now), now)

    assert heavy > light
  end

  test "score decays the longer it has been since last contact" do
    now = 100 * @day
    fresh = Score.score(stats(5, 5, now), now)
    stale = Score.score(stats(5, 5, now - 180 * @day), now)

    assert stale < fresh
    assert stale < fresh / 2
  end

  test "activity saturates so extra edits add little near the top" do
    now = 0
    a = Score.score(stats(0, 30, now), now)
    b = Score.score(stats(0, 60, now), now)

    assert a > 0.9
    assert b - a < 0.05
  end

  test "level buckets a 0.0..1.0 score into 0..4" do
    assert Score.level(0.0) == 0
    assert Score.level(0.2) == 1
    assert Score.level(0.4) == 2
    assert Score.level(0.7) == 3
    assert Score.level(0.95) == 4
  end

  test "a never-decayed heavy file is well-known; a long-cold file is unfamiliar" do
    now = 200 * @day
    well_known = Score.level(Score.score(stats(20, 40, now), now))
    long_cold = Score.level(Score.score(stats(2, 1, now - 365 * @day), now))

    assert well_known == 4
    assert long_cold == 0
  end
end
