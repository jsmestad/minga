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

  This process must be alive **before** the LoggerHandler installs its
  custom handler so that early-boot logs either land directly in the
  buffer or are captured in the ETS pre-subscribe buffer and replayed
  here on init.
  """

  use GenServer

  alias Minga.Buffer
  alias Minga.Buffer.Document
  alias Minga.Events
  alias Minga.Events.LogMessageEvent
  alias Minga.LoggerHandler

  @max_lines 1000

  @doc "Returns the pid of the singleton `*Messages*` buffer, or `nil` if not started."
  @spec pid() :: pid() | nil
  def pid do
    case Process.whereis(__MODULE__) do
      nil -> nil
      owner -> GenServer.call(owner, :buffer_pid)
    end
  end

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
    monitor = Process.monitor(buffer)

    Enum.each(LoggerHandler.flush_buffer(), fn {text, _level} ->
      append(buffer, text)
    end)

    {:ok, %{buffer: buffer, monitor: monitor}}
  end

  @impl true
  @spec handle_call(:buffer_pid, GenServer.from(), map()) :: {:reply, pid(), map()}
  def handle_call(:buffer_pid, _from, %{buffer: buffer} = state) do
    {:reply, buffer, state}
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
    {:stop, {:buffer_down, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec start_buffer() :: pid()
  defp start_buffer do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Minga.Buffer.Supervisor,
        {Buffer,
         content: "", buffer_name: "*Messages*", unlisted: true, persistent: true, read_only: true}
      )

    pid
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
      lines = String.split(content, "\n")
      trimmed = lines |> Enum.drop(excess) |> Enum.join("\n")

      :sys.replace_state(buffer, fn s ->
        %{s | document: Document.new(trimmed)}
      end)
    end

    :ok
  end
end
