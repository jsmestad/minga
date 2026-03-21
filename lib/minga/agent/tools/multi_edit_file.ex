defmodule Minga.Agent.Tools.MultiEditFile do
  @moduledoc """
  Applies multiple find-and-replace edits to a single file in one tool call.

  Routes through `Buffer.Server.find_and_replace_batch/2` when a buffer is
  open for the file (atomic batch, single undo entry, no disk I/O). Falls
  back to filesystem I/O when no buffer exists.

  Each edit is an `{old_text, new_text}` pair. Edits are applied in order.
  If any edit fails, subsequent edits still attempt and all results are reported.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  @typedoc "A single edit operation."
  @type edit :: %{String.t() => String.t()}

  @doc """
  Applies a list of edits to the file at `path`.

  Opens a buffer for the file if one doesn't exist, ensuring undo integration
  and visibility in the buffer list. Falls back to filesystem I/O only when
  the Editor is not running.

  Each edit in `edits` must have `"old_text"` and `"new_text"` keys.
  Returns `{:ok, summary}` with a per-edit status report.
  """
  @spec execute(String.t(), [edit()]) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path, edits) when is_binary(path) and is_list(edits) do
    case ensure_buffer(path) do
      {:ok, pid} -> execute_via_buffer(pid, path, edits)
      :unavailable -> execute_via_filesystem(path, edits)
    end
  end

  # ── Buffer path ──

  @spec execute_via_buffer(pid(), String.t(), [edit()]) ::
          {:ok, String.t()} | {:error, String.t()}
  defp execute_via_buffer(pid, path, edits) do
    edit_pairs =
      Enum.map(edits, fn edit ->
        {edit["old_text"] || "", edit["new_text"] || ""}
      end)

    case BufferServer.find_and_replace_batch(pid, edit_pairs) do
      {:ok, results} -> {:ok, format_buffer_results(path, results)}
      {:error, msg} -> {:error, "#{path}: #{msg}"}
    end
  catch
    :exit, _ -> {:error, "buffer process died for #{path}"}
  end

  @spec ensure_buffer(String.t()) :: {:ok, pid()} | :unavailable
  defp ensure_buffer(path) do
    case Editor.ensure_buffer_for_path(path) do
      {:ok, pid} -> {:ok, pid}
      {:error, _} -> :unavailable
    end
  catch
    :exit, _ -> :unavailable
  end

  @spec format_buffer_results(String.t(), [BufferServer.replace_result()]) :: String.t()
  defp format_buffer_results(path, results) do
    total = length(results)
    succeeded = Enum.count(results, &match?({:ok, _}, &1))
    failed = total - succeeded

    summary = "#{path}: #{succeeded}/#{total} edits applied"

    summary =
      if failed > 0 do
        summary <> " (#{failed} failed)"
      else
        summary
      end

    error_details =
      results
      |> Enum.with_index()
      |> Enum.filter(fn {{status, _}, _} -> status == :error end)
      |> Enum.map_join("\n", fn {{:error, msg}, i} -> "  edit #{i + 1}: #{msg}" end)

    if error_details == "" do
      summary
    else
      summary <> "\n" <> error_details
    end
  end

  # ── Filesystem fallback ──

  @spec execute_via_filesystem(String.t(), [edit()]) ::
          {:ok, String.t()} | {:error, String.t()}
  defp execute_via_filesystem(path, edits) do
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

  @spec apply_edits(String.t(), [edit()]) :: {String.t(), [{:ok | :error, String.t()}]}
  defp apply_edits(content, edits) do
    {final_content, results_reversed} =
      edits
      |> Enum.with_index()
      |> Enum.reduce({content, []}, fn {edit, _index}, {current_content, results} ->
        old_text = edit["old_text"] || ""
        new_text = edit["new_text"] || ""

        case apply_single_edit(current_content, old_text, new_text) do
          {:ok, updated_content} ->
            {updated_content, [{:ok, "applied"} | results]}

          {:error, msg} ->
            {current_content, [{:error, msg} | results]}
        end
      end)

    {final_content, Enum.reverse(results_reversed)}
  end

  @spec apply_single_edit(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp apply_single_edit(_content, "", _new_text) do
    {:error, "old_text is empty"}
  end

  defp apply_single_edit(content, old_text, new_text) do
    case length(:binary.matches(content, old_text)) do
      0 -> {:error, "old_text not found"}
      1 -> {:ok, String.replace(content, old_text, new_text, global: false)}
      n -> {:error, "old_text found #{n} times (ambiguous)"}
    end
  end

  @spec write_and_report(
          String.t(),
          String.t(),
          String.t(),
          [{:ok | :error, String.t()}]
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp write_and_report(path, original_content, final_content, results) do
    succeeded = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.count(results, &match?({:error, _}, &1))
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
          [{:ok | :error, String.t()}],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: String.t()
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
      |> Enum.with_index()
      |> Enum.filter(fn {{status, _}, _} -> status == :error end)
      |> Enum.map_join("\n", fn {{:error, msg}, i} -> "  edit #{i + 1}: #{msg}" end)

    if details == "" do
      summary
    else
      summary <> "\n" <> details
    end
  end
end
