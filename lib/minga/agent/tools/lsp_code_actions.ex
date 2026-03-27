defmodule Minga.Agent.Tools.LspCodeActions do
  @moduledoc """
  Agent tool that discovers and applies LSP code actions.

  Code actions include quickfixes (add missing import, fix typo),
  refactorings (extract function, inline variable), and source actions
  (organize imports, fix all). The agent can list available actions and
  optionally apply one by title or index.

  Listing is not destructive; applying is destructive (requires approval).

  Part of epic #1241. See #1246.
  """

  alias Minga.Agent.Tools.LspBridge
  alias Minga.Buffer
  alias Minga.Diagnostics
  alias Minga.LSP.WorkspaceEdit

  @doc """
  Lists or applies code actions at the given file position.

  When `apply` is nil, lists available actions. When `apply` is a string
  (action title) or integer (1-indexed position), applies that action.

  Line is 0-indexed.
  """
  @spec execute(String.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(path, line, opts \\ []) when is_binary(path) and is_integer(line) do
    abs_path = Path.expand(path)
    col = Keyword.get(opts, :col, 0)
    apply_action = Keyword.get(opts, :apply, nil)

    case LspBridge.client_for_path(abs_path) do
      {:ok, client} -> do_code_actions(client, abs_path, path, line, col, apply_action)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec do_code_actions(
          pid(),
          String.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          term()
        ) ::
          {:ok, String.t()} | {:error, String.t()}
  defp do_code_actions(client, abs_path, path, line, col, apply_action) do
    case fetch_actions(client, abs_path, line, col) do
      {:ok, []} ->
        {:ok, "No code actions available at #{Path.basename(path)}:#{line + 1}"}

      {:ok, actions} ->
        if apply_action do
          apply_selected_action(client, actions, apply_action, path)
        else
          {:ok, format_actions(path, line, actions)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private: fetch ─────────────────────────────────────────────────────────

  @spec fetch_actions(pid(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, String.t()}
  defp fetch_actions(client, abs_path, line, col) do
    uri = LspBridge.path_to_uri(abs_path)

    range = %{
      "start" => %{"line" => line, "character" => col},
      "end" => %{"line" => line, "character" => col}
    }

    diagnostics = diagnostics_at_line(uri, line)

    params = %{
      "textDocument" => %{"uri" => uri},
      "range" => range,
      "context" => %{
        "diagnostics" => diagnostics
      }
    }

    case LspBridge.request_sync(client, "textDocument/codeAction", params) do
      {:ok, nil} -> {:ok, []}
      {:ok, actions} when is_list(actions) -> {:ok, actions}
      {:error, :timeout} -> {:error, "Code actions request timed out"}
      {:error, error} -> {:error, "Code actions request failed: #{inspect(error)}"}
    end
  end

  @spec diagnostics_at_line(String.t(), non_neg_integer()) :: [map()]
  defp diagnostics_at_line(uri, line) do
    uri
    |> Diagnostics.on_line(line)
    |> Enum.map(fn diag ->
      %{
        "range" => %{
          "start" => %{"line" => diag.range.start_line, "character" => diag.range.start_col},
          "end" => %{"line" => diag.range.end_line, "character" => diag.range.end_col}
        },
        "message" => diag.message,
        "severity" => severity_to_lsp(diag.severity)
      }
    end)
  end

  # ── Private: format ────────────────────────────────────────────────────────

  @spec format_actions(String.t(), non_neg_integer(), [map()]) :: String.t()
  defp format_actions(path, line, actions) do
    header =
      "#{length(actions)} code action#{if length(actions) == 1, do: "", else: "s"} at #{Path.basename(path)}:#{line + 1}:"

    details =
      actions
      |> Enum.with_index(1)
      |> Enum.map(fn {action, idx} ->
        title = Map.get(action, "title", "Untitled")
        kind = Map.get(action, "kind", "")
        kind_str = if kind != "", do: " [#{kind}]", else: ""
        preferred = if Map.get(action, "isPreferred", false), do: " ★", else: ""
        "  #{idx}. #{title}#{kind_str}#{preferred}"
      end)

    hint =
      "\nTo apply an action, call code_actions again with apply set to the action number or title."

    Enum.join([header | details], "\n") <> hint
  end

  # ── Private: apply ─────────────────────────────────────────────────────────

  @spec apply_selected_action(pid(), [map()], String.t() | integer(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp apply_selected_action(client, actions, selection, path) do
    action = find_action(actions, selection)

    case action do
      nil ->
        {:error, "No matching code action found for #{inspect(selection)}"}

      action ->
        do_apply_action(client, action, path)
    end
  end

  @spec find_action([map()], String.t() | integer()) :: map() | nil
  defp find_action(actions, index) when is_integer(index) and index > 0 do
    Enum.at(actions, index - 1)
  end

  defp find_action(actions, title) when is_binary(title) do
    Enum.find(actions, fn a ->
      String.downcase(Map.get(a, "title", "")) == String.downcase(title)
    end)
  end

  defp find_action(_actions, _), do: nil

  @spec do_apply_action(pid(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp do_apply_action(client, action, _path) do
    # Some actions need resolving to get the full edit
    action =
      case Map.get(action, "edit") do
        nil -> resolve_action(client, action)
        _edit -> action
      end

    title = Map.get(action, "title", "code action")

    case Map.get(action, "edit") do
      nil ->
        # Action has a command but no edit; execute the command
        case Map.get(action, "command") do
          nil ->
            {:error, "Code action \"#{title}\" has no edit or command to apply"}

          command ->
            execute_command(client, command)
            {:ok, "Executed command: #{title}"}
        end

      workspace_edit ->
        file_edits = WorkspaceEdit.parse(workspace_edit)
        {file_count, edit_count, errors} = apply_file_edits(file_edits)
        result = "Applied \"#{title}\": #{edit_count} edits across #{file_count} files"

        result =
          case errors do
            [] -> result
            _ -> result <> "\nWarnings:\n" <> Enum.join(errors, "\n")
          end

        # Also execute the command if present (some actions have both edit + command)
        case Map.get(action, "command") do
          nil -> :ok
          command -> execute_command(client, command)
        end

        {:ok, result}
    end
  end

  @spec resolve_action(pid(), map()) :: map()
  defp resolve_action(client, action) do
    case LspBridge.request_sync(client, "codeAction/resolve", action) do
      {:ok, resolved} when is_map(resolved) -> resolved
      _ -> action
    end
  end

  @spec execute_command(pid(), map()) :: :ok
  defp execute_command(client, %{"command" => cmd, "arguments" => args}) do
    params = %{"command" => cmd, "arguments" => args}
    LspBridge.request_sync(client, "workspace/executeCommand", params, 10_000)
    :ok
  end

  defp execute_command(client, %{"command" => cmd}) do
    params = %{"command" => cmd, "arguments" => []}
    LspBridge.request_sync(client, "workspace/executeCommand", params, 10_000)
    :ok
  end

  defp execute_command(_client, _), do: :ok

  @spec apply_file_edits([WorkspaceEdit.file_edits()]) ::
          {non_neg_integer(), non_neg_integer(), [String.t()]}
  defp apply_file_edits(file_edits) do
    Enum.reduce(file_edits, {0, 0, []}, fn {path, edits}, {fc, ec, errs} ->
      case apply_edits_to_file(path, edits) do
        :ok -> {fc + 1, ec + length(edits), errs}
        {:error, reason} -> {fc, ec, ["  #{Path.basename(path)}: #{reason}" | errs]}
      end
    end)
  end

  @spec apply_edits_to_file(String.t(), [WorkspaceEdit.text_edit()]) :: :ok | {:error, String.t()}
  defp apply_edits_to_file(path, edits) do
    case Buffer.Server.pid_for_path(path) do
      {:ok, pid} ->
        Buffer.apply_edits(pid, edits)
        :ok

      :not_found ->
        apply_edits_via_filesystem(path, edits)
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, _ -> apply_edits_via_filesystem(path, edits)
  end

  @spec apply_edits_via_filesystem(String.t(), [WorkspaceEdit.text_edit()]) ::
          :ok | {:error, String.t()}
  defp apply_edits_via_filesystem(path, edits) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n", trim: false)

        new_lines =
          Enum.reduce(edits, lines, fn {{sl, sc}, {el, ec}, new_text}, acc ->
            apply_text_edit(acc, sl, sc, el, ec, new_text)
          end)

        File.write(path, Enum.join(new_lines, "\n"))
        :ok

      {:error, reason} ->
        {:error, "could not read: #{reason}"}
    end
  end

  @spec apply_text_edit(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: [String.t()]
  defp apply_text_edit(lines, start_line, start_col, end_line, end_col, new_text) do
    before_edit = Enum.at(lines, start_line, "") |> String.slice(0, start_col)
    after_edit = Enum.at(lines, end_line, "") |> String.slice(end_col..-1//1)

    replacement = before_edit <> new_text <> after_edit
    replacement_lines = String.split(replacement, "\n", trim: false)

    prefix = Enum.take(lines, start_line)
    suffix = Enum.drop(lines, end_line + 1)

    prefix ++ replacement_lines ++ suffix
  end

  @spec severity_to_lsp(atom()) :: non_neg_integer()
  defp severity_to_lsp(:error), do: 1
  defp severity_to_lsp(:warning), do: 2
  defp severity_to_lsp(:info), do: 3
  defp severity_to_lsp(:hint), do: 4
end
