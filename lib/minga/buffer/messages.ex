defmodule Minga.Buffer.Messages do
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
  - Trims the buffer to `@max_lines` lines so it stays bounded.

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

  @doc """
  Returns the pid of the singleton `*Messages*` buffer, or `nil` if the
  owner has never started successfully.

  Reads from `:persistent_term` so it never blocks on the owner's mailbox,
  even during heavy log bursts.
  """
  @spec pid() :: pid() | nil
  def pid, do: :persistent_term.get(__MODULE__, nil)

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
    Buffer.append(buffer, "[#{time}] #{text}\n")
    maybe_trim(buffer)
    :ok
  end

  @spec maybe_trim(pid()) :: :ok
  defp maybe_trim(buffer) do
    line_count = Buffer.line_count(buffer)

    if line_count > @max_lines do
      excess = line_count - @max_lines
      content = Buffer.content(buffer)
      trimmed = content |> String.split("\n") |> Enum.drop(excess) |> Enum.join("\n")
      Buffer.replace_content_force(buffer, trimmed)
    end

    :ok
  end
end
