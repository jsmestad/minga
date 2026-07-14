defmodule Minga.Frontend.WaitRequests do
  @moduledoc """
  Tracks CLI wait requests for files opened in the native app.

  The macOS frontend transports a target path and a result-file path, but all
  completion decisions stay on the BEAM. A successful save or accepted close
  completes a request with status 0; explicit abort/discard paths complete it
  with a non-zero status.
  """

  use GenServer

  @typedoc "Wait request completion status."
  @type completion :: :accepted | {:cancelled, String.t()}

  @typedoc "Server option."
  @type start_opt ::
          {:name, GenServer.name() | nil}
          | {:allowed_root, String.t()}

  @typep request :: %{monitor: reference(), result_paths: MapSet.t(String.t())}
  @typep state :: %{allowed_root: String.t(), requests: %{optional(pid()) => request()}}

  @doc "Starts the wait-request tracker."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case name do
      nil -> GenServer.start_link(__MODULE__, opts)
      server_name -> GenServer.start_link(__MODULE__, opts, name: server_name)
    end
  end

  @doc "Registers a successfully opened target and acknowledges the CLI shim."
  @spec register(pid(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def register(buffer, result_path, server \\ __MODULE__)
      when is_pid(buffer) and is_binary(result_path) do
    call(server, {:register, buffer, result_path}, {:error, :wait_tracker_unavailable})
  end

  @doc "Completes all requests for a buffer successfully."
  @spec accept(pid(), GenServer.server()) :: :ok
  def accept(buffer, server \\ __MODULE__) when is_pid(buffer) do
    call(server, {:complete, buffer, :accepted}, :ok)
  end

  @doc "Completes all requests for a buffer as cancelled."
  @spec cancel(pid(), String.t(), GenServer.server()) :: :ok
  def cancel(buffer, reason, server \\ __MODULE__)
      when is_pid(buffer) and is_binary(reason) do
    call(server, {:complete, buffer, {:cancelled, reason}}, :ok)
  end

  @doc "Completes every outstanding request successfully."
  @spec accept_all(GenServer.server()) :: :ok
  def accept_all(server \\ __MODULE__), do: call(server, {:complete_all, :accepted}, :ok)

  @doc "Completes every outstanding request as cancelled."
  @spec cancel_all(String.t(), GenServer.server()) :: :ok
  def cancel_all(reason, server \\ __MODULE__) when is_binary(reason) do
    call(server, {:complete_all, {:cancelled, reason}}, :ok)
  end

  @doc "Reports a target-open failure before a buffer could be registered."
  @spec fail_open(String.t(), term(), GenServer.server()) :: :ok | {:error, term()}
  def fail_open(result_path, reason, server \\ __MODULE__) when is_binary(result_path) do
    call(server, {:fail_open, result_path, reason}, {:error, :wait_tracker_unavailable})
  end

  @spec call(GenServer.server(), term(), term()) :: term()
  defp call(server, message, fallback) do
    case GenServer.whereis(server) do
      nil -> fallback
      _pid -> GenServer.call(server, message)
    end
  end

  @impl true
  @spec init([start_opt()]) :: {:ok, state()}
  def init(opts) do
    root =
      opts
      |> Keyword.get(:allowed_root, Path.join(System.tmp_dir!(), "minga-wait"))
      |> Path.expand()

    {:ok, %{allowed_root: root, requests: %{}}}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:register, buffer, result_path}, _from, state) do
    with :ok <- validate_result_path(result_path, state.allowed_root),
         :ok <- write_ack(result_path) do
      requests = put_request(state.requests, buffer, Path.expand(result_path))
      {:reply, :ok, %{state | requests: requests}}
    else
      {:error, reason} = error ->
        Minga.Log.warning(:editor, "Could not register CLI wait request: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call({:fail_open, result_path, reason}, _from, state) do
    result =
      with :ok <- validate_result_path(result_path, state.allowed_root) do
        write_result(result_path, {:cancelled, "file open failed: #{inspect(reason)}"})
      end

    {:reply, result, state}
  end

  def handle_call({:complete, buffer, completion}, _from, state) do
    {:reply, :ok, complete_buffer(state, buffer, completion)}
  end

  def handle_call({:complete_all, completion}, _from, state) do
    Enum.each(state.requests, fn {_buffer, request} ->
      complete_paths(request.result_paths, completion)
      Process.demonitor(request.monitor, [:flush])
    end)

    {:reply, :ok, %{state | requests: %{}}}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({:DOWN, monitor, :process, buffer, reason}, state) do
    case Map.get(state.requests, buffer) do
      %{monitor: ^monitor} ->
        completion = {:cancelled, "buffer exited before wait completion: #{inspect(reason)}"}
        {:noreply, complete_buffer(state, buffer, completion)}

      _other ->
        {:noreply, state}
    end
  end

  @spec put_request(%{optional(pid()) => request()}, pid(), String.t()) :: %{
          optional(pid()) => request()
        }
  defp put_request(requests, buffer, result_path) do
    case Map.get(requests, buffer) do
      nil ->
        Map.put(requests, buffer, %{
          monitor: Process.monitor(buffer),
          result_paths: MapSet.new([result_path])
        })

      request ->
        Map.put(requests, buffer, %{
          request
          | result_paths: MapSet.put(request.result_paths, result_path)
        })
    end
  end

  @spec complete_buffer(state(), pid(), completion()) :: state()
  defp complete_buffer(state, buffer, completion) do
    case Map.pop(state.requests, buffer) do
      {nil, _requests} ->
        state

      {request, requests} ->
        Process.demonitor(request.monitor, [:flush])
        complete_paths(request.result_paths, completion)
        %{state | requests: requests}
    end
  end

  @spec complete_paths(MapSet.t(String.t()), completion()) :: :ok
  defp complete_paths(paths, completion) do
    Enum.each(paths, fn path ->
      case write_result(path, completion) do
        :ok ->
          :ok

        {:error, reason} ->
          Minga.Log.warning(:editor, "Could not complete CLI wait request: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @spec validate_result_path(String.t(), String.t()) :: :ok | {:error, term()}
  defp validate_result_path(result_path, allowed_root) do
    expanded = Path.expand(result_path)
    parent = Path.dirname(expanded)
    root_prefix = allowed_root <> "/"

    with true <- String.starts_with?(parent <> "/", root_prefix),
         true <- Path.basename(expanded) == "result",
         {:ok, %{type: :directory}} <- File.stat(parent),
         false <- File.exists?(expanded) do
      :ok
    else
      false -> {:error, :invalid_result_path}
      {:ok, %{type: type}} -> {:error, {:invalid_request_directory, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec write_ack(String.t()) :: :ok | {:error, term()}
  defp write_ack(result_path) do
    result_path
    |> Path.dirname()
    |> Path.join("ack")
    |> write_exclusive("accepted\n")
  end

  @spec write_result(String.t(), completion()) :: :ok | {:error, term()}
  defp write_result(path, :accepted), do: write_exclusive(path, "0\n")

  defp write_result(path, {:cancelled, reason}) do
    message =
      reason
      |> String.replace("\n", " ")
      |> String.replace("\r", " ")
      |> String.slice(0, 500)

    write_exclusive(path, "1\t#{message}\n")
  end

  @spec write_exclusive(String.t(), iodata()) :: :ok | {:error, term()}
  defp write_exclusive(path, contents) do
    temp_path = path <> ".tmp-#{System.unique_integer([:positive])}"

    result =
      case File.write(temp_path, contents, [:exclusive]) do
        :ok -> File.ln(temp_path, path)
        {:error, _reason} = error -> error
      end

    _cleanup = File.rm(temp_path)
    result
  end
end
