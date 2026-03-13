defmodule Minga.Agent.Tools.MultiEditFile do
  @moduledoc """
  Applies multiple find-and-replace edits to a single file in one tool call.

  Each edit is an `{old_text, new_text}` pair. Edits are applied in the order
  given. If any edit fails (text not found, ambiguous match), subsequent edits
  still attempt and all results are reported. This lets the model make many
  changes to a file in a single round-trip instead of N separate `edit_file` calls.
  """

  @typedoc "A single edit operation."
  @type edit :: %{String.t() => String.t()}

  defmodule EditResult do
    @moduledoc false
    @enforce_keys [:index, :status, :message]
    defstruct [:index, :status, :message]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            status: :ok | :error,
            message: String.t()
          }
  end

  @typedoc "Result of a single edit within the batch."
  @type edit_result :: EditResult.t()

  @doc """
  Applies a list of edits to the file at `path`.

  Each edit in `edits` must have `"old_text"` and `"new_text"` keys.
  Edits are applied sequentially to the file content in memory, then the
  final result is written to disk once. If any edit fails, the file is still
  written with the edits that succeeded.

  Returns `{:ok, summary}` with a per-edit status report.
  """
  @spec execute(String.t(), [edit()]) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path, edits) when is_binary(path) and is_list(edits) do
    case File.read(path) do
      {:ok, content} ->
        {final_content, results} = apply_edits(content, edits)
        write_and_report(path, content, final_content, results)

      {:error, :enoent} ->
        {:error, "file not found: #{path}"}

      {:error, reason} ->
        {:error, "failed to read #{path}: #{reason}"}
    end
  end

  @spec apply_edits(String.t(), [edit()]) :: {String.t(), [edit_result()]}
  defp apply_edits(content, edits) do
    {final_content, results_reversed} =
      edits
      |> Enum.with_index()
      |> Enum.reduce({content, []}, fn {edit, index}, {current_content, results} ->
        old_text = edit["old_text"] || ""
        new_text = edit["new_text"] || ""

        case apply_single_edit(current_content, old_text, new_text, index) do
          {:ok, updated_content, result} ->
            {updated_content, [result | results]}

          {:error, result} ->
            {current_content, [result | results]}
        end
      end)

    {final_content, Enum.reverse(results_reversed)}
  end

  @spec apply_single_edit(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t(), edit_result()} | {:error, edit_result()}
  defp apply_single_edit(_content, "", _new_text, index) do
    {:error, %EditResult{index: index, status: :error, message: "old_text is empty"}}
  end

  defp apply_single_edit(content, old_text, new_text, index) do
    parts = String.split(content, old_text)
    occurrence_count = length(parts) - 1

    case occurrence_count do
      0 ->
        {:error, %EditResult{index: index, status: :error, message: "old_text not found"}}

      1 ->
        updated = String.replace(content, old_text, new_text, global: false)
        {:ok, updated, %EditResult{index: index, status: :ok, message: "applied"}}

      n ->
        {:error,
         %EditResult{
           index: index,
           status: :error,
           message: "old_text found #{n} times (ambiguous)"
         }}
    end
  end

  @spec write_and_report(String.t(), String.t(), String.t(), [edit_result()]) ::
          {:ok, String.t()} | {:error, String.t()}
  defp write_and_report(path, original_content, final_content, results) do
    succeeded = Enum.count(results, &(&1.status == :ok))
    failed = Enum.count(results, &(&1.status == :error))
    total = length(results)

    # Only write if something changed
    if final_content != original_content do
      case File.write(path, final_content) do
        :ok ->
          {:ok, format_report(path, results, succeeded, failed, total)}

        {:error, reason} ->
          {:error, "edits computed but failed to write #{path}: #{reason}"}
      end
    else
      {:ok, format_report(path, results, succeeded, failed, total)}
    end
  end

  @spec format_report(
          String.t(),
          [edit_result()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          String.t()
  defp format_report(path, results, succeeded, failed, total) do
    summary = "#{path}: #{succeeded}/#{total} edits applied"

    summary =
      if failed > 0 do
        summary <> " (#{failed} failed)"
      else
        summary
      end

    details =
      results
      |> Enum.filter(&(&1.status == :error))
      |> Enum.map_join("\n", fn r -> "  edit #{r.index + 1}: #{r.message}" end)

    if details == "" do
      summary
    else
      summary <> "\n" <> details
    end
  end
end
