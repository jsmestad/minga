defmodule Minga.DebugLog do
  @moduledoc """
  Crash-safe debug log writer for `*Messages*` and `*Warnings*` entries.

  The process subscribes to `:log_message` events and appends each event to a file. Writes are buffered for a short debounce window so bursts only force one disk sync, while isolated messages still reach disk quickly.
  """

  use GenServer

  alias Minga.Events
  alias Minga.Events.LogMessageEvent

  @default_flush_after 50
  @default_registry_retry_after 50

  @typedoc "Registry process name that the debug log subscribes to."
  @type registry :: Events.registry()

  @typedoc "Options for starting a debug log writer."
  @type start_opt ::
          {:name, atom() | nil}
          | {:path, path()}
          | {:registry, registry()}
          | {:registry_retry_after, pos_integer()}
          | {:flush_after, pos_integer()}

  @type start_opts :: [start_opt()]
  @type fd :: :file.io_device()
  @type path :: String.t()
  @type timer :: {reference(), reference()}
  @type registry_ref :: reference() | nil
  @type registry_pid :: pid() | nil
  @type registry_retry :: timer() | nil
  @type t :: %__MODULE__{
          path: path(),
          fd: fd(),
          buffer: iodata(),
          timer: timer() | nil,
          flush_after: pos_integer(),
          registry: registry(),
          registry_pid: registry_pid(),
          registry_ref: registry_ref(),
          registry_retry: registry_retry(),
          registry_retry_after: pos_integer(),
          registry_gap_open: boolean(),
          registry_retry_reported: boolean()
        }

  @enforce_keys [
    :path,
    :fd,
    :flush_after,
    :registry,
    :registry_pid,
    :registry_ref,
    :registry_retry_after
  ]
  defstruct [
    :path,
    :fd,
    :timer,
    :flush_after,
    :registry,
    :registry_pid,
    :registry_ref,
    :registry_retry,
    :registry_retry_after,
    :registry_gap_open,
    :registry_retry_reported,
    buffer: []
  ]

  @doc "Starts the debug log writer without linking it to the caller."
  @spec start(path() | start_opts()) :: GenServer.on_start() | :ignore
  def start(path) when is_binary(path), do: start(path: path)

  def start(opts) when is_list(opts) do
    case Keyword.get(opts, :path, Application.get_env(:minga, :debug_log_path)) do
      nil ->
        :ignore

      path when is_binary(path) ->
        start_impl(Path.expand(path), opts, :nolink)
    end
  end

  @doc "Returns a child-linked debug log writer for tests or narrow supervision use."
  @spec start_link(path() | start_opts()) :: GenServer.on_start() | :ignore
  def start_link(path) when is_binary(path), do: start_link(path: path)

  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :path, Application.get_env(:minga, :debug_log_path)) do
      nil ->
        :ignore

      path when is_binary(path) ->
        start_impl(Path.expand(path), opts, :link)
    end
  end

  @doc "Stops the named debug log writer if it is running."
  @spec stop() :: :ok | {:error, term()}
  def stop do
    case Process.whereis(__MODULE__) do
      nil ->
        case configured_path() do
          nil -> :ok
          path -> {:error, {:debug_log_not_running, path}}
        end

      pid ->
        stop(pid)
    end
  end

  @doc "Stops a debug log writer."
  @spec stop(GenServer.server()) :: :ok | {:error, term()}
  def stop(server) do
    flush_result = flush(server)
    stop_result = stop_server(server)
    resolve_stop_result(flush_result, stop_result)
  end

  @doc "Synchronously flushes the named debug log writer when it is running."
  @spec flush() :: :ok | {:error, term()}
  def flush do
    case Process.whereis(__MODULE__) do
      nil ->
        case configured_path() do
          nil -> :ok
          path -> {:error, {:debug_log_not_running, path}}
        end

      pid ->
        flush(pid)
    end
  end

  @doc "Synchronously flushes a debug log writer."
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server) do
    GenServer.call(server, :flush, 5_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Returns the path used by a running debug log writer."
  @spec path(GenServer.server()) :: path()
  def path(server), do: GenServer.call(server, :path)

  @impl true
  @spec init({path(), keyword()}) :: {:ok, t()} | {:stop, term()}
  def init({path, opts}) do
    Process.flag(:trap_exit, true)

    case File.open(path, [:append, :binary]) do
      {:ok, fd} ->
        case write_and_sync(fd, session_header()) do
          :ok ->
            init_registry(path, fd, opts)

          {:error, reason} ->
            stop_init(path, fd, {:debug_log_session_header_failed, path, reason})
        end

      {:error, reason} ->
        {:stop, {:debug_log_unwritable, path, reason}}
    end
  end

  @impl true
  @spec handle_call(:flush | :path, GenServer.from(), t()) ::
          {:reply, :ok | {:error, term()} | path(), t()} | {:stop, term(), {:error, term()}, t()}
  def handle_call(:flush, _from, state) do
    case flush_buffer(state) do
      {:ok, state} ->
        {:reply, :ok, state}

      {{:error, reason}, state} ->
        {:stop, {:debug_log_write_failed, state.path, reason}, {:error, reason}, state}
    end
  end

  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  @impl true
  @spec handle_info(term(), t()) :: {:noreply, t()} | {:stop, term(), t()}
  def handle_info({:minga_event, :log_message, %LogMessageEvent{} = event}, state) do
    state = append_event(state, event)
    {:noreply, reset_flush_timer(state)}
  end

  def handle_info(
        {:retry_registry_subscription, token},
        %__MODULE__{registry_retry: {_, token}} = state
      ) do
    retry_registry_subscription(%{state | registry_retry: nil})
  end

  def handle_info({:retry_registry_subscription, _stale_token}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %__MODULE__{registry_ref: ref, registry_pid: pid} = state
      ) do
    handle_registry_down(state, reason)
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:flush, token}, %__MODULE__{timer: {_, token}} = state) do
    flush_state(state)
  end

  def handle_info({:flush, _stale_token}, state), do: {:noreply, state}
  def handle_info(:flush, state), do: flush_state(state)

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), t()) :: :ok
  def terminate(_reason, %__MODULE__{} = state) do
    flush_result = write_buffer(state.buffer, state.fd)
    close_result = File.close(state.fd)
    report_terminate_result(flush_result, close_result, state.path)
  end

  @spec start_impl(path(), keyword(), :link | :nolink) :: GenServer.on_start()
  defp start_impl(path, opts, mode) do
    name = Keyword.get(opts, :name, __MODULE__)

    case existing_pid(name) do
      nil ->
        do_start(path, opts, mode, name)

      pid ->
        ensure_same_path(pid, path)
    end
  end

  @spec existing_pid(atom() | nil) :: pid() | nil
  defp existing_pid(nil), do: nil
  defp existing_pid(name) when is_atom(name), do: Process.whereis(name)

  @spec do_start(path(), keyword(), :link | :nolink, atom() | nil) :: GenServer.on_start()
  defp do_start(path, opts, :link, name) do
    GenServer.start_link(__MODULE__, {path, opts}, genserver_opts(name))
  end

  defp do_start(path, opts, :nolink, name) do
    GenServer.start(__MODULE__, {path, opts}, genserver_opts(name))
  end

  @spec ensure_same_path(pid(), path()) :: {:ok, pid()} | {:error, term()}
  defp ensure_same_path(pid, requested_path) do
    ensure_same_path(pid, path(pid), requested_path)
  catch
    :exit, reason -> {:error, reason}
  end

  @spec ensure_same_path(pid(), path(), path()) :: {:ok, pid()} | {:error, term()}
  defp ensure_same_path(pid, path, path), do: {:ok, pid}

  defp ensure_same_path(_pid, existing_path, requested_path) do
    {:error, {:debug_log_already_started, existing_path, requested_path}}
  end

  @spec genserver_opts(atom() | nil) :: GenServer.options()
  defp genserver_opts(nil), do: []
  defp genserver_opts(name) when is_atom(name), do: [name: name]

  @spec init_registry(path(), fd(), keyword()) :: {:ok, t()} | {:stop, term()}
  defp init_registry(path, fd, opts) do
    registry = Keyword.get(opts, :registry, Events.default_registry())
    flush_after = Keyword.get(opts, :flush_after, @default_flush_after)
    retry_after = Keyword.get(opts, :registry_retry_after, @default_registry_retry_after)

    case attach_registry(registry) do
      {:ok, registry_pid, registry_ref} ->
        {:ok,
         %__MODULE__{
           path: path,
           fd: fd,
           flush_after: flush_after,
           registry: registry,
           registry_pid: registry_pid,
           registry_ref: registry_ref,
           registry_retry_after: retry_after,
           registry_gap_open: false,
           registry_retry_reported: false
         }}

      {:error, reason} ->
        stop_init(path, fd, reason)
    end
  end

  @spec attach_registry(registry()) :: {:ok, pid(), reference()} | {:error, term()}
  defp attach_registry(registry) do
    case Process.whereis(registry) do
      nil ->
        {:error, {:debug_log_events_registry_unavailable, registry}}

      pid ->
        subscribe_to_registry(registry, pid)
    end
  end

  @spec subscribe_to_registry(registry(), pid()) :: {:ok, pid(), reference()} | {:error, term()}
  defp subscribe_to_registry(registry, pid) do
    Events.subscribe(:log_message, registry)

    if subscribed_to_registry?(registry) do
      {:ok, pid, Process.monitor(pid)}
    else
      {:error, {:debug_log_events_subscription_failed, registry}}
    end
  rescue
    error -> {:error, {:debug_log_events_subscription_failed, registry, error}}
  catch
    :exit, reason -> {:error, {:debug_log_events_subscription_failed, registry, reason}}
  end

  @spec subscribed_to_registry?(registry()) :: boolean()
  defp subscribed_to_registry?(registry) do
    Enum.any?(Events.subscribers(:log_message, registry), &(&1 == self()))
  end

  @spec retry_registry_subscription(t()) :: {:noreply, t()} | {:stop, term(), t()}
  defp retry_registry_subscription(%__MODULE__{} = state) do
    case attach_registry(state.registry) do
      {:ok, registry_pid, registry_ref} ->
        case maybe_write_registry_status_marker(
               state,
               "events registry re-subscribed; missed events may exist"
             ) do
          {:ok, state} ->
            {:noreply,
             %{
               state
               | registry_pid: registry_pid,
                 registry_ref: registry_ref,
                 registry_retry: nil,
                 registry_gap_open: false,
                 registry_retry_reported: false
             }}

          {:error, reason} ->
            {:stop, {:debug_log_write_failed, state.path, reason}, state}
        end

      {:error, reason} ->
        case maybe_write_registry_retry_failure(state, reason) do
          {:ok, state} ->
            {:noreply, schedule_registry_retry(%{state | registry_pid: nil, registry_ref: nil})}

          {:error, write_reason} ->
            {:stop, {:debug_log_write_failed, state.path, write_reason}, state}
        end
    end
  end

  @spec handle_registry_down(t(), term()) :: {:noreply, t()} | {:stop, term(), t()}
  defp handle_registry_down(%__MODULE__{} = state, reason) do
    state =
      %{
        state
        | registry_pid: nil,
          registry_ref: nil,
          registry_gap_open: true,
          registry_retry_reported: false
      }

    case maybe_write_registry_status_marker(state, "events registry down: #{inspect(reason)}") do
      {:ok, state} ->
        {:noreply, schedule_registry_retry(state)}

      {:error, write_reason} ->
        {:stop, {:debug_log_write_failed, state.path, write_reason}, state}
    end
  end

  @spec maybe_write_registry_retry_failure(t(), term()) :: {:ok, t()} | {:error, term()}
  defp maybe_write_registry_retry_failure(%__MODULE__{} = state, reason) do
    if state.registry_gap_open and not state.registry_retry_reported do
      case maybe_write_registry_status_marker(
             state,
             "events registry retry failed: #{inspect(reason)}"
           ) do
        {:ok, state} -> {:ok, %{state | registry_retry_reported: true}}
        {:error, write_reason} -> {:error, write_reason}
      end
    else
      {:ok, state}
    end
  end

  @spec maybe_write_registry_status_marker(t(), String.t()) :: {:ok, t()} | {:error, term()}
  defp maybe_write_registry_status_marker(%__MODULE__{} = state, message) do
    case flush_buffer(state) do
      {:ok, state} ->
        case write_registry_marker(state.fd, message) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason}
        end

      {{:error, reason}, _state} ->
        {:error, reason}
    end
  end

  @spec write_registry_marker(fd(), String.t()) :: :ok | {:error, term()}
  defp write_registry_marker(fd, message) do
    write_and_sync(fd, [registry_marker_prefix(), message, "\n"])
  end

  @spec registry_marker_prefix() :: String.t()
  defp registry_marker_prefix, do: "[debug-log] "

  @spec schedule_registry_retry(t()) :: t()
  defp schedule_registry_retry(%__MODULE__{} = state) do
    cancel_registry_retry(state.registry_retry)
    token = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:retry_registry_subscription, token},
        state.registry_retry_after
      )

    %{state | registry_retry: {timer_ref, token}}
  end

  @spec cancel_registry_retry(registry_retry()) :: :ok
  defp cancel_registry_retry(nil), do: :ok

  defp cancel_registry_retry({timer_ref, _token}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  end

  @spec stop_init(path(), fd(), term()) :: {:stop, term()}
  defp stop_init(path, fd, reason) do
    case File.close(fd) do
      :ok ->
        {:stop, {:debug_log_init_failed, path, reason}}

      {:error, close_reason} ->
        {:stop, {:debug_log_init_failed, path, reason, {:close_failed, close_reason}}}
    end
  end

  @spec append_event(t(), LogMessageEvent.t()) :: t()
  defp append_event(%__MODULE__{buffer: buffer} = state, %LogMessageEvent{} = event) do
    %{state | buffer: [buffer, format_event(event)]}
  end

  @spec reset_flush_timer(t()) :: t()
  defp reset_flush_timer(%__MODULE__{} = state) do
    cancel_timer(state.timer)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:flush, token}, state.flush_after)
    %{state | timer: {timer_ref, token}}
  end

  @spec cancel_timer(timer() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer({timer_ref, _token}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  end

  @spec flush_state(t()) :: {:noreply, t()} | {:stop, term(), t()}
  defp flush_state(state) do
    case flush_buffer(state) do
      {:ok, state} -> {:noreply, state}
      {{:error, reason}, state} -> {:stop, {:debug_log_write_failed, state.path, reason}, state}
    end
  end

  @spec flush_buffer(t()) :: {:ok, t()} | {{:error, term()}, t()}
  defp flush_buffer(%__MODULE__{buffer: []} = state), do: {:ok, %{state | timer: nil}}

  defp flush_buffer(%__MODULE__{fd: fd, buffer: buffer} = state) do
    case write_buffer(buffer, fd) do
      :ok -> {:ok, %{state | buffer: [], timer: nil}}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @spec write_buffer(iodata(), fd()) :: :ok | {:error, term()}
  defp write_buffer([], _fd), do: :ok
  defp write_buffer(buffer, fd), do: write_and_sync(fd, buffer)

  @spec write_and_sync(fd(), iodata()) :: :ok | {:error, term()}
  defp write_and_sync(fd, data) do
    case :file.write(fd, data) do
      :ok -> :file.datasync(fd)
      {:error, _reason} = error -> error
    end
  end

  @spec stop_server(GenServer.server()) :: :ok | {:error, term()}
  defp stop_server(server) do
    GenServer.stop(server)
    :ok
  catch
    :exit, reason -> {:error, reason}
  end

  @spec resolve_stop_result(:ok | {:error, term()}, :ok | {:error, term()}) ::
          :ok | {:error, term()}
  defp resolve_stop_result(:ok, :ok), do: :ok
  defp resolve_stop_result(:ok, {:error, :noproc}), do: :ok
  defp resolve_stop_result(:ok, {:error, {:noproc, _}}), do: :ok
  defp resolve_stop_result(:ok, {:error, reason}), do: {:error, reason}
  defp resolve_stop_result({:error, :noproc}, _stop_result), do: :ok
  defp resolve_stop_result({:error, {:noproc, _}}, _stop_result), do: :ok
  defp resolve_stop_result({:error, reason}, _stop_result), do: {:error, reason}

  @spec configured_path() :: path() | nil
  defp configured_path, do: Application.get_env(:minga, :debug_log_path)

  @spec report_terminate_result(:ok | {:error, term()}, :ok | {:error, term()}, path()) :: :ok
  defp report_terminate_result(:ok, :ok, _path), do: :ok

  defp report_terminate_result({:error, reason}, close_result, path) do
    IO.puts(:stderr, "Debug log final flush failed for #{path}: #{inspect(reason)}")
    report_close_result(close_result, path)
  end

  defp report_terminate_result(:ok, close_result, path),
    do: report_close_result(close_result, path)

  @spec report_close_result(:ok | {:error, term()}, path()) :: :ok
  defp report_close_result(:ok, _path), do: :ok

  defp report_close_result({:error, reason}, path) do
    IO.puts(:stderr, "Debug log close failed for #{path}: #{inspect(reason)}")
    :ok
  end

  @spec format_event(LogMessageEvent.t()) :: iodata()
  defp format_event(%LogMessageEvent{text: text, level: :warning}), do: lines(text, "[WARNING] ")
  defp format_event(%LogMessageEvent{text: text, level: :error}), do: lines(text, "[ERROR] ")
  defp format_event(%LogMessageEvent{text: text}), do: lines(text, "")

  @spec lines(String.t(), String.t()) :: iodata()
  defp lines(text, prefix) do
    text
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map(fn line -> [prefix, line, "\n"] end)
  end

  @spec session_header() :: iodata()
  defp session_header do
    [
      "\n--- Minga debug log session ---\n",
      "Minga ",
      Minga.version(),
      " | Elixir ",
      System.version(),
      " | OTP ",
      otp_release(),
      " | ",
      DateTime.utc_now() |> DateTime.to_iso8601(),
      "\n"
    ]
  end

  @spec otp_release() :: String.t()
  defp otp_release, do: :erlang.system_info(:otp_release) |> List.to_string()
end
