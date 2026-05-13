defmodule MingaEditor.Commands.RemoteFiles do
  @moduledoc "Commands for browsing remote files in read-only local buffers."

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Distribution.ConnectionManager
  alias Minga.Distribution.File, as: RemoteFile
  alias Minga.Language
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Remote

  @type state :: EditorState.t()

  @doc "Opens a picker for remote files on the active remote session's server."
  @spec find_remote_file(state()) :: state()
  def find_remote_file(state) do
    with {:ok, server_name, remote_node} <- remote_target(state),
         {:ok, root} <- remote_cwd(remote_node) do
      PickerUI.open(state, MingaEditor.UI.Picker.RemoteFileSource, %{
        server_name: server_name,
        node: remote_node,
        root: root
      })
    else
      {:error, message} -> EditorState.set_status(state, message)
    end
  end

  @doc "Opens a remote file as a local read-only buffer."
  @spec open_remote_file(state(), String.t(), String.t()) :: state()
  def open_remote_file(state, server_name, remote_path)
      when is_binary(server_name) and is_binary(remote_path) do
    case ConnectionManager.node_for_server(server_name) do
      {:ok, remote_node} ->
        open_remote_file(state, server_name, remote_node, remote_path)

      {:error, :disconnected} ->
        EditorState.set_status(state, "Remote server #{server_name} is disconnected")

      {:error, :not_found} ->
        EditorState.set_status(state, "Unknown remote server #{server_name}")
    end
  end

  @impl Minga.Command.Provider
  def __commands__ do
    [
      %Minga.Command{
        name: :remote_find_file,
        description: "Find file on remote server",
        requires_buffer: false,
        execute: &find_remote_file/1
      }
    ]
  end

  @spec open_remote_file(state(), String.t(), node(), String.t()) :: state()
  defp open_remote_file(state, server_name, remote_node, remote_path) do
    case RemoteFile.read(remote_node, remote_path) do
      {:ok, content} ->
        start_remote_buffer(state, server_name, remote_path, content)

      {:error, reason} ->
        EditorState.set_status(state, "Failed to read remote file: #{inspect(reason)}")
    end
  end

  @spec start_remote_buffer(state(), String.t(), String.t(), binary()) :: state()
  defp start_remote_buffer(state, server_name, remote_path, content) do
    name = "[#{server_name}] #{Path.basename(remote_path)}"
    filetype = Language.detect_filetype(remote_path)

    case Buffer.start_link(
           content: content,
           buffer_name: name,
           filetype: filetype,
           read_only: true,
           buffer_type: :nofile
         ) do
      {:ok, buffer} ->
        state
        |> EditorState.add_buffer(buffer)
        |> EditorState.update_remote(&Remote.put_buffer(&1, server_name, remote_path, buffer))

      {:error, reason} ->
        EditorState.set_status(state, "Failed to open remote file: #{inspect(reason)}")
    end
  end

  @spec remote_target(state()) :: {:ok, String.t(), node()} | {:error, String.t()}
  defp remote_target(state) do
    case AgentAccess.session(state) do
      pid when is_pid(pid) and node(pid) != node() -> target_for_remote_pid(pid)
      _ -> target_for_connected_servers()
    end
  end

  @spec target_for_remote_pid(pid()) :: {:ok, String.t(), node()} | {:error, String.t()}
  defp target_for_remote_pid(pid) do
    remote_node = node(pid)

    case ConnectionManager.server_name_for_node(remote_node) do
      {:ok, server_name} -> {:ok, server_name, remote_node}
      {:error, :not_found} -> {:error, "Remote server is not configured"}
    end
  end

  @spec target_for_connected_servers() :: {:ok, String.t(), node()} | {:error, String.t()}
  defp target_for_connected_servers do
    connected =
      ConnectionManager.connected_nodes()
      |> Enum.filter(fn {_server_name, _node, status} -> status == :connected end)

    target_for_connected_servers(connected)
  end

  @spec target_for_connected_servers([{String.t(), node(), atom()}]) ::
          {:ok, String.t(), node()} | {:error, String.t()}
  defp target_for_connected_servers([{server_name, remote_node, _status}]),
    do: {:ok, server_name, remote_node}

  defp target_for_connected_servers([]), do: {:error, "No connected remote servers"}

  defp target_for_connected_servers(_servers),
    do: {:error, "Open a remote agent session first, or use the remote session picker"}

  @spec remote_cwd(node()) :: {:ok, String.t()} | {:error, String.t()}
  defp remote_cwd(remote_node) do
    {:ok, :erpc.call(remote_node, File, :cwd!, [], 5_000)}
  catch
    :exit, reason -> {:error, "Remote server unavailable: #{inspect(reason)}"}
  end
end
