defmodule Minga.Perf.ProductionGateTest do
  use ExUnit.Case, async: true

  alias Minga.Perf.ProductionGate

  defp passing(overrides \\ %{}) do
    Map.merge(
      %{
        full_resets: 0,
        changelog_consumes: 1,
        lines_fetched: 8,
        rows_composed: 8,
        swift_chunks_touched: 4,
        editor_rows_visited: 28,
        visible_rows: 24,
        overscan_rows: 4,
        decorations_visited: 99,
        request_bytes: 256 * 1024,
        receipt_bytes: 256 * 1024
      },
      overrides
    )
  end

  test "exact deterministic and payload boundaries pass while decorations remain separate" do
    assert ProductionGate.failures(passing()) == []
  end

  test "failure seams reject extra reset, consume, scan, composition, chunks, and oversized terms" do
    seams = [
      %{full_resets: 1},
      %{changelog_consumes: 2},
      %{lines_fetched: 9},
      %{rows_composed: 9},
      %{swift_chunks_touched: 5},
      %{editor_rows_visited: 29},
      %{request_bytes: 256 * 1024 + 1},
      %{receipt_bytes: 256 * 1024 + 1}
    ]

    assert Enum.all?(seams, fn seam -> ProductionGate.failures(passing(seam)) != [] end)
  end
end
