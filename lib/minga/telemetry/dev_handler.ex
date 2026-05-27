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
  | `[:minga, :render, :window_model_build, :stop]` | `:render` | `[render:window_model] 142µs (win 1)` |
  | `[:minga, :render, :ui_model_build, :stop]` | `:render` | `[render:ui_model] 38µs` |
  | `[:minga, :render, :adapter_encode, :stop]` | `:render` | `[render:adapter_encode] 22µs (rows: 3600B, overlays: 340B, gutter: 120B, ann: 60B, meta: 80B, metal_ui: 40B, chrome: 140B, frame_cmds: 980B)` |
  | `[:minga, :render, :emit_prepare, :stop]` | `:render` | `[render:emit_prepare] 8µs (5360 bytes)` |
  | `[:minga, :port, :write, :stop]` | `:port` | `[port:write] 12µs (5360 bytes)` |
  | `[:minga, :input, :dispatch, :stop]` | `:editor` | `[input:dispatch] 85µs` |
  | `[:minga, :command, :execute, :stop]` | `:editor` | `[command:move_down] 12µs` |
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
        [:minga, :render, :window_model_build, :stop],
        [:minga, :render, :ui_model_build, :stop],
        [:minga, :render, :adapter_encode, :stop],
        [:minga, :render, :emit_prepare, :stop],
        [:minga, :port, :write, :stop],
        [:minga, :input, :dispatch, :stop],
        [:minga, :command, :execute, :stop]
      ],
      &__MODULE__.handle_event/4,
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

  def handle_event([:minga, :render, :window_model_build, :stop], measurements, metadata, _config) do
    duration = measurements.duration
    window_id = Map.get(metadata, :window_id, :unknown)

    Minga.Log.debug(:render, fn ->
      "[render:window_model] #{to_microseconds(duration)}µs (win #{window_id})"
    end)
  end

  def handle_event([:minga, :render, :ui_model_build, :stop], measurements, _metadata, _config) do
    duration = measurements.duration
    Minga.Log.debug(:render, fn -> "[render:ui_model] #{to_microseconds(duration)}µs" end)
  end

  def handle_event([:minga, :render, :adapter_encode, :stop], measurements, metadata, _config) do
    duration = measurements.duration

    Minga.Log.debug(:render, fn ->
      "[render:adapter_encode] #{to_microseconds(duration)}µs (rows: #{Map.get(metadata, :window_row_bytes, 0)}B, overlays: #{Map.get(metadata, :window_overlay_bytes, 0)}B, gutter: #{Map.get(metadata, :window_gutter_bytes, 0)}B, ann: #{Map.get(metadata, :window_annotation_bytes, 0)}B, meta: #{Map.get(metadata, :window_metadata_bytes, 0)}B, metal_ui: #{Map.get(metadata, :metal_ui_bytes, 0)}B, chrome: #{Map.get(metadata, :chrome_bytes, 0)}B, frame_cmds: #{Map.get(metadata, :frame_cmd_bytes, 0)}B)"
    end)
  end

  def handle_event([:minga, :render, :emit_prepare, :stop], measurements, metadata, _config) do
    duration = measurements.duration
    byte_count = Map.get(metadata, :byte_count, 0)

    Minga.Log.debug(:render, fn ->
      "[render:emit_prepare] #{to_microseconds(duration)}µs (#{byte_count} bytes)"
    end)
  end

  def handle_event([:minga, :port, :write, :stop], measurements, metadata, _config) do
    duration = measurements.duration
    byte_count = Map.get(metadata, :byte_count, 0)

    Minga.Log.debug(:port, fn ->
      "[port:write] #{to_microseconds(duration)}µs (#{byte_count} bytes)"
    end)
  end

  def handle_event([:minga, :command, :execute, :stop], measurements, metadata, _config) do
    duration = measurements.duration
    command = Map.get(metadata, :command, :unknown)
    Minga.Log.debug(:editor, fn -> "[command:#{command}] #{to_microseconds(duration)}µs" end)
  end

  # Catch-all for any future events that aren't handled yet.
  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec to_microseconds(integer()) :: integer()
  defp to_microseconds(native_duration) do
    System.convert_time_unit(native_duration, :native, :microsecond)
  end
end
