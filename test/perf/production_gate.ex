defmodule Minga.Perf.ProductionGate do
  @moduledoc """
  Deterministic production-render budget comparator.

  Measurements are operation counts emitted by the shipping render pipeline,
  never elapsed time. Keeping policy here gives CI one fail-closed comparator
  and gives failure-seam tests a way to prove every boundary is enforced.
  """

  @max_boundary_bytes 256 * 1024
  @max_lines 8
  @max_swift_chunks 4

  @type measurement :: %{
          required(:full_resets) => non_neg_integer(),
          required(:changelog_consumes) => non_neg_integer(),
          required(:lines_fetched) => non_neg_integer(),
          required(:rows_composed) => non_neg_integer(),
          required(:swift_chunks_touched) => non_neg_integer(),
          required(:editor_rows_visited) => non_neg_integer(),
          required(:visible_rows) => non_neg_integer(),
          required(:overscan_rows) => non_neg_integer(),
          required(:decorations_visited) => non_neg_integer(),
          required(:request_bytes) => non_neg_integer(),
          required(:receipt_bytes) => non_neg_integer()
        }

  @doc "Returns every deterministic production-gate violation."
  @spec failures(measurement()) :: [String.t()]
  def failures(measurement),
    do:
      beam_failures(measurement) ++ swift_failures(measurement) ++ boundary_failures(measurement)

  @doc "Checks only work owned and measured by the BEAM render pipeline."
  @spec beam_failures(measurement()) :: [String.t()]
  def beam_failures(measurement) do
    []
    |> exceed(measurement.full_resets, 0, "full resets")
    |> differ(measurement.changelog_consumes, 1, "ChangeLog consumes")
    |> exceed(measurement.lines_fetched, @max_lines, "logical lines fetched")
    |> exceed(measurement.rows_composed, @max_lines, "rows composed")
    |> Enum.reverse()
  end

  @doc "Checks only work owned and measured by Swift row preparation."
  @spec swift_failures(measurement()) :: [String.t()]
  def swift_failures(measurement) do
    []
    |> exceed(measurement.swift_chunks_touched, @max_swift_chunks, "Swift chunks touched")
    |> exceed(
      measurement.editor_rows_visited,
      measurement.visible_rows + measurement.overscan_rows,
      "editor rows visited"
    )
    |> Enum.reverse()
  end

  @doc "Checks serialized BEAM process-boundary terms."
  @spec boundary_failures(measurement()) :: [String.t()]
  def boundary_failures(measurement) do
    []
    |> exceed(measurement.request_bytes, @max_boundary_bytes, "RenderIntent bytes")
    |> exceed(measurement.receipt_bytes, @max_boundary_bytes, "RenderReceipt bytes")
    |> Enum.reverse()
  end

  @spec exceed([String.t()], non_neg_integer(), non_neg_integer(), String.t()) :: [String.t()]
  defp exceed(failures, actual, limit, label) when actual > limit,
    do: ["#{label} #{actual} exceeds #{limit}" | failures]

  defp exceed(failures, _actual, _limit, _label), do: failures

  @spec differ([String.t()], non_neg_integer(), non_neg_integer(), String.t()) :: [String.t()]
  defp differ(failures, expected, expected, _label), do: failures

  defp differ(failures, actual, expected, label),
    do: ["#{label} #{actual} must equal #{expected}" | failures]
end
