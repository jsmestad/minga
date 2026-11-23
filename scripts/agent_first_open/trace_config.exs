# Measurement-only Minga user config for scripts/agent_first_open/measure.py.
#
# The driver installs this file as config.exs in a private profile. It attaches one
# telemetry handler that forwards each listed event to a writer process, which appends
# one JSON line per event to $MINGA_AGENT_OPEN_TRACE. Each line carries the OS wall
# clock in microseconds when the handler ran, so the driver can place BEAM events on
# the same clock as its key posts. For a span stop, start_us is the stop time minus the
# span duration. A SessionStart hook is added only when $MINGA_AGENT_OPEN_HOOK is set.

use Minga.Config

defmodule MingaAgentOpenTrace do
  @agent_spans [
    :catalog_load,
    :tab_switch,
    :start_agent_session,
    :ensure_configured_model,
    :project_view_overlay,
    :session_manager_start,
    :session_init,
    :session_model_resolve,
    :session_subscribe,
    :provider_project_view_refresh,
    :session_snapshot_read,
    :provider_start,
    :session_start_hooks,
    :session_start_hook_config
  ]

  @events [
            [:minga, :input, :dispatch, :start],
            [:minga, :input, :dispatch, :stop],
            [:minga, :command, :execute, :stop],
            [:minga, :render, :pipeline, :stop],
            [:minga, :port, :write, :stop],
            [:minga, :editor, :code_warmup, :stop]
          ] ++ Enum.map(@agent_spans, &[:minga, :agent, &1, :stop])

  @spec start(Path.t()) :: :ok
  def start(path) do
    writer = spawn(fn -> write_loop(File.open!(path, [:append, :binary])) end)
    :telemetry.attach_many("minga-agent-open-trace", @events, &__MODULE__.handle/4, writer)
    send(writer, {:line, %{at_us: :os.system_time(:microsecond), event: "trace_ready"}})
    :ok
  end

  @spec handle([atom()], map(), map(), pid()) :: term()
  def handle(event, measurements, metadata, writer) do
    at = :os.system_time(:microsecond)

    line =
      %{at_us: at, event: Enum.map_join(event, ".", &Atom.to_string/1), pid: inspect(self())}
      |> put_duration(measurements, at)
      |> Map.merge(Map.take(metadata, [:input_seq, :frame_seq, :command, :byte_count]))
      |> Map.update(:command, nil, &inspect/1)

    send(writer, {:line, line})
  end

  defp put_duration(line, %{duration: duration}, at) do
    us = System.convert_time_unit(duration, :native, :microsecond)
    Map.merge(line, %{duration_us: us, start_us: at - us})
  end

  defp put_duration(line, _measurements, _at), do: line

  defp write_loop(io) do
    receive do
      {:line, line} ->
        IO.binwrite(io, [JSON.encode!(line), ?\n])
        write_loop(io)
    end
  end
end

MingaAgentOpenTrace.start(System.fetch_env!("MINGA_AGENT_OPEN_TRACE"))

case System.get_env("MINGA_AGENT_OPEN_HOOK") do
  nil -> :ok
  command -> set(:agent_hooks, [%{event: "SessionStart", command: command, timeout_ms: 5_000}])
end
