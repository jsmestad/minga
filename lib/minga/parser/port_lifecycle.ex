defmodule Minga.Parser.PortLifecycle do
  @moduledoc """
  Focused parser Port startup, shutdown, writes, restart timing, and failure replies.

  It performs ordering-sensitive effects but does not construct or update manager
  or domain-state structs. The manager installs values through their owner modules.
  """

  alias Minga.Parser.Protocol
  alias Minga.Parser.RequestHandler
  alias Minga.Parser.RequestState
  alias Minga.Parser.SnippetState

  @max_backoff_ms 5_000
  @max_restart_attempts 5
  @restart_window_ms 30_000

  @type start_result :: {:ok, port()} | :unavailable
  @type schedule_result ::
          :unchanged | {:scheduled, [integer()], pos_integer()} | {:gave_up, [integer()]}
  @type restart_result :: {:restarted, port()} | :unavailable | :unchanged

  @doc "Starts the parser executable when it exists."
  @spec start(String.t()) :: start_result()
  def start(parser_path) do
    if File.exists?(parser_path) do
      {:ok,
       Port.open(
         {:spawn_executable, parser_path},
         [:binary, :exit_status, {:packet, 4}, :use_stdio]
       )}
    else
      Minga.Log.warning(:port, "Parser binary not found at #{parser_path}")
      :unavailable
    end
  end

  @doc "Closes the current parser Port."
  @spec close(port() | nil) :: :ok
  def close(nil), do: :ok

  def close(port) do
    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  @doc "Sends an encoded command batch, returning false when the Port is gone."
  @spec send_batch(port() | nil, [binary()]) :: boolean()
  def send_batch(nil, _commands), do: false

  def send_batch(port, commands) do
    payload = IO.iodata_to_binary(commands)

    try do
      Port.command(port, payload, [:nosuspend])
    rescue
      ArgumentError -> false
    catch
      :exit, _reason -> false
    end
  end

  @doc "Closes one parser-side buffer when both Port and identity exist."
  @spec close_buffer(port() | nil, pos_integer() | nil) :: :ok
  def close_buffer(_port, nil), do: :ok
  def close_buffer(nil, _buffer_id), do: :ok

  def close_buffer(port, buffer_id) do
    _sent? = send_batch(port, [Protocol.encode_close_buffer(buffer_id)])
    :ok
  end

  @doc "Replaces the current Port and reports whether startup succeeded."
  @spec manual_restart(port() | nil, String.t()) :: restart_result()
  def manual_restart(handle, parser_path) do
    :ok = close(handle)

    case start(parser_path) do
      {:ok, handle} ->
        Minga.Log.info(:port, "Parser: manual restart successful")
        {:restarted, handle}

      :unavailable ->
        :unavailable
    end
  end

  @doc "Schedules a bounded exponential-backoff restart unless retries gave up."
  @spec schedule_restart(boolean(), [integer()], pos_integer(), %{pid() => reference()}) ::
          schedule_result()
  def schedule_restart(true, _timestamps, _backoff_ms, _subscribers), do: :unchanged

  def schedule_restart(false, timestamps, backoff_ms, subscribers) do
    now = System.monotonic_time(:millisecond)
    recent = Enum.filter(timestamps, fn timestamp -> now - timestamp < @restart_window_ms end)
    schedule_restart_attempt([now | recent], backoff_ms, subscribers)
  end

  @doc "Attempts a scheduled restart."
  @spec attempt_restart(boolean(), port() | nil, String.t()) :: restart_result()
  def attempt_restart(true, _handle, _parser_path), do: :unchanged
  def attempt_restart(false, handle, _parser_path) when handle != nil, do: :unchanged

  def attempt_restart(false, nil, parser_path) do
    case start(parser_path) do
      {:ok, handle} ->
        Minga.Log.info(:port, "Parser: restarted successfully")
        {:restarted, handle}

      :unavailable ->
        :unavailable
    end
  end

  @doc "Fails every synchronous parser and snippet request."
  @spec fail_pending(RequestState.t(), SnippetState.t()) ::
          {RequestState.t(), SnippetState.t()}
  def fail_pending(requests, snippets) do
    requests = RequestHandler.fail_all(requests)
    {pending, snippets} = SnippetState.take_all(snippets)

    Enum.each(pending, fn request ->
      Process.cancel_timer(request.timer_ref)
      GenServer.reply(request.from, :unavailable)
    end)

    {requests, snippets}
  end

  @spec schedule_restart_attempt([integer()], pos_integer(), %{pid() => reference()}) ::
          schedule_result()
  defp schedule_restart_attempt([_, _, _, _, _ | _] = recent, _backoff_ms, subscribers) do
    Minga.Log.error(
      :port,
      "Parser crashed repeatedly (#{@max_restart_attempts} times in #{div(@restart_window_ms, 1000)}s), syntax highlighting disabled. Use :parser-restart to retry."
    )

    Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{
      text:
        "Parser crashed repeatedly, syntax highlighting disabled. Use :parser-restart to retry.",
      level: :warning
    })

    broadcast(subscribers, {:minga_highlight, :parser_gave_up})
    {:gave_up, recent}
  end

  defp schedule_restart_attempt(recent, backoff_ms, _subscribers) do
    Minga.Log.info(
      :port,
      "Parser: scheduling restart in #{backoff_ms}ms (attempt #{length(recent)}/#{@max_restart_attempts})"
    )

    Process.send_after(self(), :restart_parser, backoff_ms)
    {:scheduled, recent, min(backoff_ms * 2, @max_backoff_ms)}
  end

  @spec broadcast(%{pid() => reference()}, term()) :: :ok
  defp broadcast(subscribers, message) do
    subscribers |> Map.keys() |> Enum.each(&send(&1, message))
  end
end
