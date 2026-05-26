defmodule MingaEditor.Input.Observatory do
  @moduledoc """
  Handles BEAM Observatory GUI actions.

  The Observatory is a native GUI sidebar, but inspection is BEAM-owned: the frontend sends a PID string, and this module formats a bounded, user-readable snapshot for the existing native float popup.
  """

  alias Minga.Buffer
  alias MingaEditor.Observatory.Inspection
  alias MingaEditor.State, as: EditorState

  @type state :: EditorState.t()
  @type process_class :: :supervisor | :buffer | :agent_session | :lsp | :service | :worker

  @doc "Inspects a process selected in the BEAM Observatory."
  @spec inspect_process(state(), String.t()) :: state()
  def inspect_process(state, "") do
    EditorState.set_observatory_inspection(state, nil)
  end

  def inspect_process(state, pid_string) when is_binary(pid_string) do
    inspection =
      pid_string
      |> parse_pid()
      |> build_inspection(state, pid_string)

    EditorState.set_observatory_inspection(state, inspection)
  end

  @spec parse_pid(String.t()) :: {:ok, pid()} | :error
  defp parse_pid(pid_string) do
    {:ok, :erlang.list_to_pid(String.to_charlist(pid_string))}
  rescue
    ArgumentError -> :error
  end

  @spec build_inspection({:ok, pid()} | :error, state(), String.t()) :: Inspection.t()
  defp build_inspection(:error, _state, pid_string) do
    popup("Process #{pid_string}", ["Invalid BEAM PID"])
  end

  defp build_inspection({:ok, pid}, state, pid_string) do
    process_class = find_process_class(state, pid)

    lines =
      case get_process_state(pid) do
        {:ok, process_state} -> format_process_state(process_state, process_class, pid)
        {:error, reason} -> format_process_info(pid, reason)
      end

    popup("Process #{pid_string}", lines)
  end

  @spec get_process_state(pid()) :: {:ok, term()} | {:error, term()}
  defp get_process_state(pid) do
    {:ok, :sys.get_state(pid, 2_000)}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec find_process_class(state(), pid()) :: process_class()
  defp find_process_class(%{shell_state: %{observatory_data: %{tree: tree}}}, pid) do
    tree
    |> Minga.SystemObserver.TreeNode.flatten()
    |> Enum.find_value(:worker, fn node ->
      if node.pid == pid, do: node.snapshot.process_class, else: nil
    end)
  end

  defp find_process_class(_state, _pid), do: :worker

  @spec format_process_state(term(), process_class(), pid()) :: [String.t()]
  defp format_process_state(process_state, :buffer, pid) do
    [
      "Class: buffer",
      "Path: #{safe_buffer_path(pid)}",
      "Lines: #{safe_buffer_line_count(pid)}",
      "Bytes: #{byte_size(safe_buffer_content(pid))}",
      "",
      truncated_inspect(process_state)
    ]
  end

  defp format_process_state(process_state, :agent_session, _pid) do
    [
      "Class: agent session",
      "",
      summarize_map_field(process_state, :messages, "Conversation entries"),
      summarize_map_field(process_state, :files_touched, "Files touched"),
      summarize_map_field(process_state, :token_usage, "Token usage"),
      "",
      truncated_inspect(process_state)
    ]
  end

  defp format_process_state(process_state, :lsp, _pid) do
    ["Class: LSP", "", truncated_inspect(process_state)]
  end

  defp format_process_state(process_state, process_class, _pid) do
    ["Class: #{process_class}", "", truncated_inspect(process_state)]
  end

  @spec format_process_info(pid(), term()) :: [String.t()]
  defp format_process_info(pid, reason) do
    info = Process.info(pid) || []

    [
      "GenServer state unavailable: #{inspect(reason)}",
      "",
      "Process info:",
      truncated_inspect(info)
    ]
  end

  @spec popup(String.t(), [String.t()]) :: Inspection.t()
  defp popup(title, lines) do
    Inspection.visible(title, lines)
  end

  @spec safe_buffer_path(pid()) :: String.t()
  defp safe_buffer_path(pid) do
    Buffer.file_path(pid) || "[no file]"
  catch
    :exit, _ -> "[unavailable]"
  end

  @spec safe_buffer_line_count(pid()) :: non_neg_integer()
  defp safe_buffer_line_count(pid) do
    Buffer.line_count(pid)
  catch
    :exit, _ -> 0
  end

  @spec safe_buffer_content(pid()) :: String.t()
  defp safe_buffer_content(pid) do
    Buffer.content(pid)
  catch
    :exit, _ -> ""
  end

  @spec summarize_map_field(term(), atom(), String.t()) :: String.t()
  defp summarize_map_field(process_state, key, label) when is_map(process_state) do
    case Map.get(process_state, key) do
      value when is_list(value) -> "#{label}: #{length(value)}"
      value when is_map(value) -> "#{label}: #{map_size(value)}"
      nil -> "#{label}: unknown"
      value -> "#{label}: #{inspect(value, limit: 20)}"
    end
  end

  defp summarize_map_field(_process_state, _key, label), do: "#{label}: unknown"

  @spec truncated_inspect(term()) :: String.t()
  defp truncated_inspect(term) do
    term
    |> inspect(limit: 500, printable_limit: 4_000, pretty: true)
    |> String.slice(0, 4_000)
  end
end
