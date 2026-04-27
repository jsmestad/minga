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

  # The last two rows of the screen (modeline + message bar) can pick up
  # state from concurrent tests: LSP status icons (◯), tool installer
  # progress messages, diagnostic counts, etc. These are not part of the
  # editor content being tested. Normalizing them before comparison
  # prevents false snapshot mismatches.
  #
  # Row height-2 = modeline: mask everything after the mode indicator and
  #   file name (the right side can show LSP icons, diagnostics, etc.)
  # Row height-1 = message bar: can show log_to_messages output from any
  #   concurrent editor process via PubSub
  @spec normalize_volatile_rows([String.t()], pos_integer()) :: [String.t()]
  def normalize_volatile_rows(rows, width) do
    total = length(rows)
    modeline_idx = total - 2
    message_bar_idx = total - 1

    rows
    |> Enum.with_index()
    |> Enum.map(fn
      {row, ^modeline_idx} -> normalize_modeline(row, width)
      {row, ^message_bar_idx} -> normalize_message_bar(row)
      {row, _} -> row
    end)
  end

  # Replace known volatile segments (LSP status icons, diagnostic counts)
  # with spaces, keeping total row length identical so alignment is preserved.
  # Known volatile patterns in the modeline:
  #   " ◯ " (LSP starting), " ● " (LSP active), " ✓ " (LSP idle/ready)
  #   " E:N " or " W:N " (diagnostic counts)
  @spec normalize_modeline(String.t(), pos_integer()) :: String.t()
  defp normalize_modeline(row, _width) do
    row
    |> replace_with_spaces(~r/ [◯●✓] /u)
    |> replace_with_spaces(~r/ [EW]:\d+ /)
  end

  # Replace each match with the same number of space characters,
  # preserving the total string length and alignment.
  @spec replace_with_spaces(String.t(), Regex.t()) :: String.t()
  defp replace_with_spaces(str, regex) do
    Regex.replace(regex, str, fn match ->
      String.duplicate(" ", String.length(match))
    end)
  end

  # Strip known volatile messages that leak from concurrent tests.
  # Keeps intentional content (command prompts like ":", ":set", etc.)
  @spec normalize_message_bar(String.t()) :: String.t()
  defp normalize_message_bar(row) do
    # Known volatile patterns from concurrent tests:
    # - Tool installer progress: "pyright: Stub verifying pyright..."
    # - LSP status messages: "elixir-ls: connected", "pyright: starting"
    # - Log messages from other editors: "[filename] saved", etc.
    cond do
      # Command mode prompt: starts with ":" (keep as-is)
      String.starts_with?(row, ":") -> row
      # Search prompt: starts with "/" or "?" (keep as-is)
      String.starts_with?(row, "/") or String.starts_with?(row, "?") -> row
      # Eval prompt: starts with ">" (keep as-is)
      String.starts_with?(row, ">") -> row
      # Empty or whitespace-only: keep as-is (normal state)
      String.trim(row) == "" -> row
      # Anything else on the message bar is volatile (log messages,
      # tool progress, etc. from concurrent tests)
      true -> ""
    end
  end

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
        canonical_current = normalize_serialized_snapshot(current)
        canonical_baseline = normalize_serialized_snapshot(baseline)

        if canonical_current == canonical_baseline do
          :match
        else
          {:mismatch, build_diff(canonical_baseline, canonical_current)}
        end

      {:error, :enoent} ->
        {:no_baseline, baseline_path}
    end
  end

  @spec normalize_serialized_snapshot(String.t()) :: String.t()
  defp normalize_serialized_snapshot(snapshot) do
    modeline_prefix = serialized_modeline_prefix(snapshot)

    snapshot
    |> String.split("\n")
    |> Enum.map(&normalize_serialized_line(&1, modeline_prefix))
    |> Enum.join("\n")
  end

  @spec serialized_modeline_prefix(String.t()) :: String.t() | nil
  defp serialized_modeline_prefix(snapshot) do
    case Regex.run(~r/# Screen: \d+x(\d+)/, snapshot) do
      [_match, height] -> height |> String.to_integer() |> Kernel.-(2) |> row_prefix()
      _ -> nil
    end
  end

  @spec row_prefix(integer()) :: String.t() | nil
  defp row_prefix(row) when row >= 0 do
    row |> Integer.to_string() |> String.pad_leading(2, "0") |> Kernel.<>("│")
  end

  defp row_prefix(_row), do: nil

  @spec normalize_serialized_line(String.t(), String.t() | nil) :: String.t()
  defp normalize_serialized_line(line, nil), do: line

  defp normalize_serialized_line(line, prefix) do
    if String.starts_with?(line, prefix) do
      prefix <> normalize_modeline(String.trim_leading(line, prefix), String.length(line))
    else
      line
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
