defmodule ChangesetFs.Server do
  @moduledoc """
  Serves changeset file content over a Unix domain socket.

  This is the BEAM side of the FSKit overlay. The FSKit extension connects
  to this server and makes lookup/read/readdir/getattr requests. The server
  resolves each request against the changeset's modifications and the real
  project directory.

  The server handles multiple concurrent FSKit connections (one per mount).
  Each connection runs in its own acceptor process.

  ## Performance target

  A `mix compile` reading 500 source files generates ~500 READ requests
  plus ~50 READDIR requests. At 50µs per request over the socket, that's
  ~27ms total overhead. The target is <100µs per request including socket
  round-trip.
  """

  use GenServer

  alias ChangesetFs.Protocol

  require Logger

  @type state :: %{
          project_root: String.t(),
          modifications: %{String.t() => binary()},
          deletions: MapSet.t(String.t()),
          socket_path: String.t(),
          listen_socket: :gen_tcp.socket() | nil,
          acceptor_pid: pid() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Updates the modifications map (called by the changeset when files change)."
  @spec update_file(pid(), String.t(), binary()) :: :ok
  def update_file(server, path, content) do
    GenServer.call(server, {:update_file, path, content})
  end

  @doc "Marks a file as deleted."
  @spec delete_file(pid(), String.t()) :: :ok
  def delete_file(server, path) do
    GenServer.call(server, {:delete_file, path})
  end

  @doc "Returns the socket path for FSKit to connect to."
  @spec socket_path(pid()) :: String.t()
  def socket_path(server) do
    GenServer.call(server, :socket_path)
  end

  @impl true
  def init(opts) do
    project_root = Keyword.fetch!(opts, :project_root)
    modifications = Keyword.get(opts, :modifications, %{})
    deletions = Keyword.get(opts, :deletions, MapSet.new())

    socket_path = Path.join(System.tmp_dir!(), "changeset-fs-#{:rand.uniform(999_999)}.sock")

    # Clean up any stale socket
    File.rm(socket_path)

    case :gen_tcp.listen(0, [
           :binary,
           packet: 4,
           active: false,
           reuseaddr: true,
           ifaddr: {:local, String.to_charlist(socket_path)}
         ]) do
      {:ok, listen_socket} ->
        # Start acceptor loop
        parent = self()
        acceptor = spawn_link(fn -> accept_loop(listen_socket, parent) end)

        {:ok,
         %{
           project_root: project_root,
           modifications: modifications,
           deletions: deletions,
           socket_path: socket_path,
           listen_socket: listen_socket,
           acceptor_pid: acceptor
         }}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_call({:update_file, path, content}, _from, state) do
    state = put_in(state.modifications[path], content)
    state = %{state | deletions: MapSet.delete(state.deletions, path)}
    {:reply, :ok, state}
  end

  def handle_call({:delete_file, path}, _from, state) do
    state = %{state | modifications: Map.delete(state.modifications, path)}
    state = %{state | deletions: MapSet.put(state.deletions, path)}
    {:reply, :ok, state}
  end

  def handle_call(:socket_path, _from, state) do
    {:reply, state.socket_path, state}
  end

  def handle_call({:fs_request, request}, _from, state) do
    response = handle_fs_request(request, state)
    {:reply, response, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.listen_socket, do: :gen_tcp.close(state.listen_socket)
    File.rm(state.socket_path)
  end

  # ── Acceptor loop ──────────────────────────────────────────────────

  defp accept_loop(listen_socket, server) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client} ->
        spawn(fn -> client_loop(client, server) end)
        accept_loop(listen_socket, server)

      {:error, :closed} ->
        :ok
    end
  end

  defp client_loop(socket, server) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        case Protocol.decode_request(data) do
          {:ok, request} ->
            response = GenServer.call(server, {:fs_request, request})
            :gen_tcp.send(socket, response)

          {:error, :unknown_opcode} ->
            :gen_tcp.send(socket, Protocol.encode_error(:io, "unknown opcode"))
        end

        client_loop(socket, server)

      {:error, :closed} ->
        :ok
    end
  end

  # ── Request handlers ───────────────────────────────────────────────

  defp handle_fs_request({:lookup, parent_path, name}, state) do
    path = join_path(parent_path, name)

    cond do
      MapSet.member?(state.deletions, path) ->
        Protocol.encode_error(:not_found, "deleted")

      Map.has_key?(state.modifications, path) ->
        content = Map.fetch!(state.modifications, path)
        Protocol.encode_ok_item(:file, byte_size(content), path)

      true ->
        real = Path.join(state.project_root, path)

        cond do
          File.regular?(real) ->
            {:ok, stat} = File.stat(real)
            Protocol.encode_ok_item(:file, stat.size, path)

          File.dir?(real) ->
            Protocol.encode_ok_item(:directory, 0, path)

          true ->
            Protocol.encode_error(:not_found, path)
        end
    end
  end

  defp handle_fs_request({:read, path, offset, count}, state) do
    cond do
      MapSet.member?(state.deletions, path) ->
        Protocol.encode_error(:deleted, path)

      Map.has_key?(state.modifications, path) ->
        content = Map.fetch!(state.modifications, path)
        slice = binary_part(content, min(offset, byte_size(content)),
                           min(count, max(byte_size(content) - offset, 0)))
        Protocol.encode_ok_data(slice)

      true ->
        real = Path.join(state.project_root, path)

        case File.read(real) do
          {:ok, content} ->
            slice = binary_part(content, min(offset, byte_size(content)),
                               min(count, max(byte_size(content) - offset, 0)))
            Protocol.encode_ok_data(slice)

          {:error, _} ->
            Protocol.encode_error(:not_found, path)
        end
    end
  end

  defp handle_fs_request({:readdir, path}, state) do
    real_dir = Path.join(state.project_root, path)

    # Start with real directory entries
    real_entries =
      case File.ls(real_dir) do
        {:ok, names} ->
          Enum.flat_map(names, fn name ->
            child_path = join_path(path, name)

            if MapSet.member?(state.deletions, child_path) do
              []
            else
              real_child = Path.join(real_dir, name)

              cond do
                Map.has_key?(state.modifications, child_path) ->
                  [{name, :file, byte_size(Map.fetch!(state.modifications, child_path))}]

                File.regular?(real_child) ->
                  {:ok, stat} = File.stat(real_child)
                  [{name, :file, stat.size}]

                File.dir?(real_child) ->
                  [{name, :directory, 0}]

                true ->
                  []
              end
            end
          end)

        {:error, _} ->
          []
      end

    # Add new files from modifications that are in this directory
    new_entries =
      state.modifications
      |> Enum.filter(fn {mod_path, _} ->
        Path.dirname(mod_path) == path and
          not Enum.any?(real_entries, fn {name, _, _} -> name == Path.basename(mod_path) end)
      end)
      |> Enum.map(fn {mod_path, content} ->
        {Path.basename(mod_path), :file, byte_size(content)}
      end)

    Protocol.encode_ok_entries(real_entries ++ new_entries)
  end

  defp handle_fs_request({:getattr, path}, state) do
    cond do
      MapSet.member?(state.deletions, path) ->
        Protocol.encode_error(:not_found, "deleted")

      Map.has_key?(state.modifications, path) ->
        content = Map.fetch!(state.modifications, path)
        now = System.os_time(:second)
        Protocol.encode_ok_attr(:file, byte_size(content), now, 0o644)

      true ->
        real = Path.join(state.project_root, path)

        case File.stat(real) do
          {:ok, stat} ->
            type = if stat.type == :directory, do: :directory, else: :file
            mtime = stat.mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")
                    |> DateTime.to_unix()
            Protocol.encode_ok_attr(type, stat.size, mtime, stat.mode)

          {:error, _} ->
            Protocol.encode_error(:not_found, path)
        end
    end
  end

  defp handle_fs_request({:write, path, _offset, data}, state) do
    GenServer.call(self(), {:update_file, path, data})
    Protocol.encode_ok()
  rescue
    _ -> Protocol.encode_error(:io, "write failed")
  end

  defp handle_fs_request({:create, parent, name, _type}, _state) do
    path = join_path(parent, name)
    Protocol.encode_ok_item(:file, 0, path)
  end

  defp handle_fs_request({:remove, parent, name}, _state) do
    _path = join_path(parent, name)
    Protocol.encode_ok()
  end

  defp join_path("", name), do: name
  defp join_path(".", name), do: name
  defp join_path(parent, name), do: Path.join(parent, name)
end
