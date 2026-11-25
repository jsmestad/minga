defmodule Minga.LoggerHandler.StderrRedirect do
  @moduledoc """
  Owns the redirect of `:standard_error` to the log file.

  A terminal frontend draws on the terminal the VM also writes to, so `Minga.LoggerHandler.install/0` moves `:standard_error` to the log file. A file process exits when the process that opened it exits. This holder opens the file, so the redirect lives as long as the holder does and an Editor crash does not touch it.

  ## What each failure leaves behind

    * The Editor crashes and restarts: nothing changes. The Editor's next `install/0` finds the redirect in place.
    * The log-file process dies: the holder, which monitors it, opens the file again. If that fails, it registers the original device.
    * The holder stops or fails in a callback: it registers the original device before it exits. After a failure its supervisor starts it again and it reinstalls the redirect.
    * The holder is killed: the name is unregistered until its supervisor has started it again, which reinstalls the redirect.

  ## Before the application starts

  The `minga` Mix task asks for the redirect before the supervision tree exists, so boot output does not paint over the terminal. `redirect/1` then swaps the device in the calling process and records the request. The holder adopts the request when it starts: it opens its own file, registers it, and closes the caller's.

  The record is kept in `:persistent_term` because it must outlive the holder. It is not the answer to "is the redirect installed": that is whether the holder's own device is alive and registered.
  """

  use GenServer

  alias Minga.Log

  @typedoc "The registered name of the device this holder redirects."
  @type device_name :: atom()

  @typep redirect :: %{original: pid(), device: pid(), monitor: reference(), path: String.t()}
  @typep request :: %{original: pid(), path: String.t(), interim: pid() | nil}
  @typep state :: %{device_name: device_name(), redirect: redirect() | nil}

  @doc """
  Starts the holder.

  `:name` registers the holder (default: this module). `:device_name` is the registered device to redirect (default: `:standard_error`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.get(opts, :device_name, :standard_error), name: name)
  end

  @doc """
  Redirects `:standard_error` to `log_path` through the application's holder.

  Before the application has started, the calling process holds the redirect until the holder adopts it.
  """
  @spec redirect(String.t()) :: :ok | {:error, term()}
  def redirect(log_path) when is_binary(log_path) do
    case Process.whereis(__MODULE__) do
      nil -> redirect_without_holder(:standard_error, log_path)
      _holder -> redirect(__MODULE__, log_path)
    end
  end

  @doc "Redirects the holder's device to `log_path`. Does nothing when the redirect is already in place."
  @spec redirect(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def redirect(server, log_path) when is_binary(log_path),
    do: GenServer.call(server, {:redirect, log_path})

  @doc "Registers the original `:standard_error` again through the application's holder."
  @spec restore() :: :ok
  def restore do
    case Process.whereis(__MODULE__) do
      nil -> restore_without_holder(:standard_error)
      _holder -> restore(__MODULE__)
    end
  end

  @doc "Registers the holder's original device again and closes the log file."
  @spec restore(GenServer.server()) :: :ok
  def restore(server), do: GenServer.call(server, :restore)

  @doc "Tells whether the holder's own device is alive and registered."
  @spec redirected?(GenServer.server()) :: boolean()
  def redirected?(server \\ __MODULE__), do: GenServer.call(server, :redirected?)

  @doc false
  # The redirect for a device whose holder has not started yet. The caller owns the file until a holder adopts it.
  @spec redirect_without_holder(device_name(), String.t()) :: :ok | {:error, term()}
  def redirect_without_holder(device_name, log_path) do
    case {recorded(device_name), Process.whereis(device_name)} do
      {%{}, _registered} ->
        :ok

      {nil, nil} ->
        {:error, :device_not_registered}

      {nil, original} ->
        with {:ok, device} <- open_and_register(device_name, log_path) do
          record(device_name, %{original: original, path: log_path, interim: device})
        end
    end
  end

  @doc false
  @spec restore_without_holder(device_name()) :: :ok
  def restore_without_holder(device_name) do
    case recorded(device_name) do
      nil ->
        :ok

      %{original: original, interim: interim} ->
        register_original(device_name, original)
        close(interim)
        forget(device_name)
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  @spec init(device_name()) :: {:ok, state()}
  def init(device_name) do
    Process.flag(:trap_exit, true)
    {:ok, adopt(%{device_name: device_name, redirect: nil}, recorded(device_name))}
  end

  @impl true
  @spec handle_call({:redirect, String.t()} | :restore | :redirected?, GenServer.from(), state()) ::
          {:reply, :ok | {:error, term()} | boolean(), state()}
  def handle_call({:redirect, log_path}, _from, %{redirect: nil} = state) do
    case Process.whereis(state.device_name) do
      nil ->
        {:reply, {:error, :device_not_registered}, state}

      original ->
        {result, state} = install(state, original, log_path)
        {:reply, result, state}
    end
  end

  def handle_call({:redirect, _log_path}, _from, %{redirect: %{device: device}} = state) do
    # The redirect is in place when this holder's device is alive under the name. Anything else is repaired.
    # A device that died while this call waited in the mailbox is found here, before its `:DOWN` is read.
    if Process.whereis(state.device_name) == device do
      {:reply, :ok, state}
    else
      {result, state} = reinstall(state)
      {:reply, result, state}
    end
  end

  def handle_call(:restore, _from, state), do: {:reply, :ok, put_back_original(state, :forget)}

  def handle_call(:redirected?, _from, %{redirect: nil} = state), do: {:reply, false, state}

  def handle_call(:redirected?, _from, %{redirect: %{device: device}} = state),
    do: {:reply, Process.whereis(state.device_name) == device, state}

  # A file process monitors its owner but is not linked to it, so the holder monitors the file process back.
  @impl true
  @spec handle_info(
          {:DOWN, reference(), :process, pid(), term()} | {:EXIT, pid(), term()},
          state()
        ) ::
          {:noreply, state()}
  def handle_info({:DOWN, ref, :process, _device, _reason}, %{redirect: %{monitor: ref}} = state) do
    {_result, state} = reinstall(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _stale, :process, _pid, _reason}, state), do: {:noreply, state}

  # Exits are trapped so `terminate/2` runs when the supervisor stops the holder. No linked process matters here.
  def handle_info({:EXIT, _linked, _reason}, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), state()) :: state()
  def terminate(reason, state) when reason in [:normal, :shutdown],
    do: put_back_original(state, :forget)

  def terminate({:shutdown, _detail}, state), do: put_back_original(state, :forget)

  # After a failure the record stays, so the restarted holder installs the redirect again.
  def terminate(_failure, state), do: put_back_original(state, :remember)

  # ── Transitions ─────────────────────────────────────────────────────────────

  # A record left by a caller before the application started, or by a holder that died, is installed again.
  @spec adopt(state(), request() | nil) :: state()
  defp adopt(state, nil), do: state

  defp adopt(state, %{original: original, path: path, interim: interim}) do
    {_result, state} = install(state, original, path)
    close(interim)
    state
  end

  @spec install(state(), pid(), String.t()) :: {:ok | {:error, term()}, state()}
  defp install(state, original, log_path) do
    case open_and_register(state.device_name, log_path) do
      {:ok, device} ->
        record(state.device_name, %{original: original, path: log_path, interim: nil})

        redirect = %{
          original: original,
          device: device,
          monitor: Process.monitor(device),
          path: log_path
        }

        {:ok, %{state | redirect: redirect}}

      {:error, reason} = error ->
        register_original(state.device_name, original)
        forget(state.device_name)
        Log.warning(:editor, "Could not move standard error to #{log_path}: #{inspect(reason)}")
        {error, %{state | redirect: nil}}
    end
  end

  # Replaces a device that died or lost the name with a new one on the same log file.
  @spec reinstall(state()) :: {:ok | {:error, term()}, state()}
  defp reinstall(
         %{redirect: %{original: original, device: device, monitor: monitor, path: path}} = state
       ) do
    Process.demonitor(monitor, [:flush])
    close(device)
    install(%{state | redirect: nil}, original, path)
  end

  @spec put_back_original(state(), :forget | :remember) :: state()
  defp put_back_original(%{redirect: nil} = state, _record), do: state

  defp put_back_original(
         %{redirect: %{original: original, device: device} = redirect} = state,
         record
       ) do
    Process.demonitor(redirect.monitor, [:flush])
    register_original(state.device_name, original)
    close(device)
    if record == :forget, do: forget(state.device_name)
    %{state | redirect: nil}
  end

  # ── The registered name ─────────────────────────────────────────────────────

  @spec open_and_register(device_name(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp open_and_register(device_name, log_path) do
    with {:ok, device} <- File.open(log_path, [:append, :utf8]) do
      register(device_name, device)
      {:ok, device}
    end
  end

  # The original device is a VM service. If it is gone there is nothing to register, and the name stays free.
  # A process that is exiting still looks alive for a moment, so a failed registration means the same thing.
  @spec register_original(device_name(), pid()) :: :ok
  defp register_original(device_name, original) do
    register(device_name, original)
  rescue
    ArgumentError -> :ok
  end

  @spec register(device_name(), pid()) :: :ok
  defp register(device_name, device) do
    unregister(device_name)
    Process.register(device, device_name)
    :ok
  end

  @spec unregister(device_name()) :: :ok
  defp unregister(device_name) do
    Process.unregister(device_name)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec close(pid() | nil) :: :ok
  defp close(nil), do: :ok

  defp close(device) do
    _result = File.close(device)
    :ok
  end

  # ── The record that outlives the holder ─────────────────────────────────────

  @spec recorded(device_name()) :: request() | nil
  defp recorded(device_name), do: :persistent_term.get({__MODULE__, device_name}, nil)

  @spec record(device_name(), request()) :: :ok
  defp record(device_name, record), do: :persistent_term.put({__MODULE__, device_name}, record)

  @spec forget(device_name()) :: :ok
  defp forget(device_name) do
    _existed? = :persistent_term.erase({__MODULE__, device_name})
    :ok
  end
end
