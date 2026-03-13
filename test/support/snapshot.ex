defmodule Minga.Test.Snapshot do
  @moduledoc """
  Screen snapshot testing for the headless editor harness.

  Serializes the `HeadlessPort` screen grid to a human-readable text file
  and diffs against a stored baseline. When the screen output changes, the
  test fails with a line-by-line diff. Developers accept intentional
  changes by running with `UPDATE_SNAPSHOTS=1 mix test`.

  ## How it works

  1. The test calls `assert_screen_snapshot(ctx, "name")` after setting up
     the editor state it wants to verify.
  2. The macro captures the full screen grid, cursor position, cursor shape,
     and editor mode from the HeadlessPort.
  3. It serializes this into a plain-text format that renders well in
     `git diff` and GitHub PR review.
  4. On first run (no baseline), it writes the file and passes with a
     warning. On subsequent runs, it compares against the stored baseline.
  5. Any difference fails the test with a clear diff.

  Snapshot files live in `test/snapshots/` with paths derived from the test
  module and snapshot name.
  """

  @snapshot_dir "test/snapshots"

  @typedoc "Metadata captured alongside the screen grid."
  @type metadata :: %{
          cursor: {non_neg_integer(), non_neg_integer()},
          cursor_shape: atom(),
          mode: atom(),
          width: pos_integer(),
          height: pos_integer()
        }

  # ── Serialization ──────────────────────────────────────────────────────────

  @doc """
  Serializes a screen (list of row strings) and metadata into the
  snapshot text format.
  """
  @spec serialize([String.t()], metadata()) :: String.t()
  def serialize(rows, metadata) do
    header = build_header(metadata)
    separator = String.duplicate("─", metadata.width)
    body = build_body(rows)

    Enum.join([header, separator, body, separator, ""], "\n")
  end

  @spec build_header(metadata()) :: String.t()
  defp build_header(metadata) do
    {cr, cc} = metadata.cursor

    [
      "# Screen: #{metadata.width}x#{metadata.height}",
      "# Cursor: (#{cr}, #{cc}) #{metadata.cursor_shape}",
      "# Mode: #{metadata.mode}"
    ]
    |> Enum.join("\n")
  end

  @spec build_body([String.t()]) :: String.t()
  defp build_body(rows) do
    rows
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {row, i} ->
      # Pad row index to 2 digits for alignment
      idx = String.pad_leading(Integer.to_string(i), 2, "0")
      "#{idx}│#{row}"
    end)
  end

  # ── Comparison ─────────────────────────────────────────────────────────────

  @doc """
  Compares a current snapshot string against a stored baseline file.

  Returns `:match` if identical, `{:mismatch, diff}` with a human-readable
  diff string if different, or `{:no_baseline, path}` if no baseline file
  exists yet.
  """
  @spec compare(String.t(), String.t()) ::
          :match | {:mismatch, String.t()} | {:no_baseline, String.t()}
  def compare(current, baseline_path) do
    case File.read(baseline_path) do
      {:ok, baseline} ->
        if current == baseline do
          :match
        else
          {:mismatch, build_diff(baseline, current)}
        end

      {:error, :enoent} ->
        {:no_baseline, baseline_path}
    end
  end

  @spec build_diff(String.t(), String.t()) :: String.t()
  defp build_diff(expected, actual) do
    expected_lines = String.split(expected, "\n")
    actual_lines = String.split(actual, "\n")

    max_lines = max(length(expected_lines), length(actual_lines))

    diff_lines =
      for i <- 0..(max_lines - 1) do
        exp = Enum.at(expected_lines, i, "")
        act = Enum.at(actual_lines, i, "")

        if exp == act do
          "  #{exp}"
        else
          "- #{exp}\n+ #{act}"
        end
      end

    Enum.join(diff_lines, "\n")
  end

  # ── Path computation ───────────────────────────────────────────────────────

  @doc """
  Computes the snapshot file path from a test module and snapshot name.

  Maps `Minga.IntegrationTest` + `"navigate_hjkl"` to
  `test/snapshots/minga/integration_test/navigate_hjkl.snap`.
  """
  @spec snapshot_path(module(), String.t()) :: String.t()
  def snapshot_path(test_module, snapshot_name) do
    module_path =
      test_module
      |> Module.split()
      |> Enum.map(&Macro.underscore/1)
      |> Path.join()

    Path.join([@snapshot_dir, module_path, "#{snapshot_name}.snap"])
  end

  # ── Update mode ────────────────────────────────────────────────────────────

  @doc "Returns true when `UPDATE_SNAPSHOTS` env var is set."
  @spec update_mode?() :: boolean()
  def update_mode? do
    System.get_env("UPDATE_SNAPSHOTS") != nil
  end

  # ── File I/O ───────────────────────────────────────────────────────────────

  @doc "Writes a snapshot to disk, creating directories as needed."
  @spec write!(String.t(), String.t()) :: :ok
  def write!(path, content) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
  end
end
