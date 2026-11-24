defmodule Minga.Log.MessagesBuffer do
  @moduledoc """
  Owner of the BEAM-wide singleton `*Messages*` buffer.

  One process, one buffer pid, regardless of how many editors are running.
  This matches `emacs --daemon` semantics: a single message log that
  outlives any individual frame (editor) and is available even in
  headless mode where no editor exists.

  ## Responsibilities

  - Starts and supervises a single `Minga.Buffer` process under
    `Minga.Buffer.Supervisor` with `buffer_name: "*Messages*"`.
  - Subscribes to the `:log_message` Events topic and appends every
    broadcast entry to that buffer with a timestamp prefix.
  - Drains any entries the `Minga.LoggerHandler` ETS pre-subscribe
    buffer captured before this process was up.
  - Trims the buffer to `@max_lines` lines and `@max_bytes` total bytes
    using a single atomic `Buffer.bounded_append/4` call per entry.

  ## Bounds

  Three independent limits keep the buffer from growing without bound:

  - `@max_lines` (1000) — newest N entries retained, oldest dropped.
  - `@max_bytes` (512 KB) — total retained bytes; additional oldest
    lines are dropped when the byte limit is reached before the line limit.
  - `@max_entry_bytes` (8 KB) — individual entries are truncated at a
    UTF-8 boundary before they reach the buffer.

  ## Boot order

  `Minga.LoggerHandler.install_messages_handler/0` runs at application
  start, before this process is supervised. Logs emitted during early
  boot land in the LoggerHandler ETS pre-subscribe buffer; this process
  drains that buffer in `init/1`, so no entries are lost.
  """

  use GenServer

  alias Minga.Buffer
  alias Minga.Events
  alias Minga.Events.LogMessageEvent
  alias Minga.LoggerHandler

  @max_lines 1000
  @max_bytes 512_000
  @max_entry_bytes 8_192

  @doc """
  Returns the pid of the singleton `*Messages*` buffer, or `nil` if the
  owner has never started successfully.

  Reads from `:persistent_term` so it never blocks on the owner's mailbox,
  even during heavy log bursts.
  """
  @spec pid() :: pid() | nil
  def pid, do: :persistent_term.get(__MODULE__, nil)

  @doc "Maximum number of lines retained in the buffer."
  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @doc "Maximum total bytes retained in the buffer."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "Maximum bytes per individual entry before truncation."
  @spec max_entry_bytes() :: pos_integer()
  def max_entry_bytes, do: @max_entry_bytes

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec init(keyword()) :: {:ok, %{buffer: pid(), monitor: reference()}}
  def init(_opts) do
    Events.subscribe(:log_message)

    buffer = start_buffer()
    :persistent_term.put(__MODULE__, buffer)
    monitor = Process.monitor(buffer)

    Enum.each(LoggerHandler.flush_buffer(), fn {text, _level} ->
      try do
        append(buffer, text)
      rescue
        _ -> :ok
      end
    end)

    {:ok, %{buffer: buffer, monitor: monitor}}
  end

  @impl true
  @spec handle_info(term(), map()) :: {:noreply, map()} | {:stop, term(), map()}
  def handle_info(
        {:minga_event, :log_message, %LogMessageEvent{text: text}},
        %{buffer: buffer} = state
      ) do
    append(buffer, text)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor: ref} = state) do
    :persistent_term.erase(__MODULE__)
    {:stop, {:buffer_down, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec start_buffer() :: pid()
  defp start_buffer do
    case DynamicSupervisor.start_child(
           Minga.Buffer.Supervisor,
           {Buffer,
            content: "",
            buffer_name: "*Messages*",
            unlisted: true,
            persistent: true,
            read_only: true}
         ) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, reason} -> raise "failed to start *Messages* buffer: #{inspect(reason)}"
    end
  end

  @spec append(pid(), String.t()) :: :ok
  defp append(buffer, text) do
    time = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")
    entry = truncate_entry("[#{time}] #{text}")
    Buffer.bounded_append(buffer, entry <> "\n", @max_lines, @max_bytes)
    :ok
  end

  @spec truncate_entry(String.t()) :: String.t()
  defp truncate_entry(text) when byte_size(text) <= @max_entry_bytes, do: text

  defp truncate_entry(text) do
    String.byte_slice(text, 0, @max_entry_bytes) <> "...[truncated]"
  end
end
