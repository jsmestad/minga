defmodule Minga.Telemetry.DevHandler do
  @moduledoc """
  Development telemetry handler that routes span durations through `Minga.Log`.

  Always attached at application startup. The handler checks the effective
  log level for the appropriate subsystem at emit time, so changing
  `:log_level_render` at runtime takes effect immediately without
  reattaching.

  ## Attaching

  Called once in `Minga.Application.start/2` before the supervision tree:

      Minga.Telemetry.DevHandler.attach()

  ## Events Handled

  | Event | Subsystem | Format |
  |-------|-----------|--------|
  | `[:minga, :render, :stage, :stop]` | `:render` | `[render:content] 42µs` |
  | `[:minga, :render, :pipeline, :stop]` | `:render` | `[render:total] 312µs` |
  | `[:minga, :input, :dispatch, :stop]` | `:editor` | `[input:dispatch] 85µs` |
  | `[:minga, :command, :execute, :stop]` | `:editor` | `[command:move_down] 12µs` |
  | `[:minga, :port, :emit, :stop]` | `:render` | `[port:emit] 48µs (1234 bytes)` |
  """

  @handler_id "minga-dev-handler"

  @doc """
  Attaches the development telemetry handler.

  Idempotent: detaches any existing handler with the same ID first.
  """
  @spec attach() :: :ok
  def attach do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      [
        [:minga, :render, :pipeline, :stop],
        [:minga, :render, :stage, :stop],
        [:minga, :input, :dispatch, :stop],
        [:minga, :command, :execute, :stop],
        [:minga, :port, :emit, :stop]
      ],
      &handle_event/4,
      nil
    )

    :ok
  end

  @doc "Detaches the development telemetry handler."
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    :telemetry.detach(@handler_id)
  end

  # ── Event Handlers ────────────────────────────────────────────────────────

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:minga, :render, :stage, :stop], measurements, metadata, _config) do
    duration = measurements.duration
    stage = metadata.stage
    Minga.Log.debug(:render, fn -> "[render:#{stage}] #{to_microseconds(duration)}µs" end)
  end

  def handle_event([:minga, :render, :pipeline, :stop], measurements, _metadata, _config) do
    duration = measurements.duration
    Minga.Log.debug(:render, fn -> "[render:total] #{to_microseconds(duration)}µs" end)
  end

  def handle_event([:minga, :input, :dispatch, :stop], measurements, _metadata, _config) do
    duration = measurements.duration
    Minga.Log.debug(:editor, fn -> "[input:dispatch] #{to_microseconds(duration)}µs" end)
  end

  def handle_event([:minga, :command, :execute, :stop], measurements, metadata, _config) do
    duration = measurements.duration
    command = Map.get(metadata, :command, :unknown)
    Minga.Log.debug(:editor, fn -> "[command:#{command}] #{to_microseconds(duration)}µs" end)
  end

  def handle_event([:minga, :port, :emit, :stop], measurements, metadata, _config) do
    duration = measurements.duration
    byte_count = Map.get(metadata, :byte_count, 0)

    Minga.Log.debug(:render, fn ->
      "[port:emit] #{to_microseconds(duration)}µs (#{byte_count} bytes)"
    end)
  end

  # Catch-all for any future events that aren't handled yet.
  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec to_microseconds(integer()) :: integer()
  defp to_microseconds(native_duration) do
    System.convert_time_unit(native_duration, :native, :microsecond)
  end
end
