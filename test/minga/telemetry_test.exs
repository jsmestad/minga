defmodule Minga.TelemetryTest do
  use ExUnit.Case, async: true

  alias Minga.Telemetry

  describe "span/3" do
    test "returns the function's result" do
      result = Telemetry.span([:minga, :test, :example], %{}, fn -> 42 end)
      assert result == 42
    end

    test "emits start and stop events" do
      self = self()

      :telemetry.attach_many(
        "test-span-events",
        [
          [:minga, :test, :span, :start],
          [:minga, :test, :span, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.span([:minga, :test, :span], %{key: :value}, fn -> :ok end)

      assert_received {:telemetry, [:minga, :test, :span, :start], %{system_time: _},
                       %{key: :value}}

      assert_received {:telemetry, [:minga, :test, :span, :stop], %{duration: duration},
                       %{key: :value}}

      assert is_integer(duration)
      assert duration >= 0
    after
      :telemetry.detach("test-span-events")
    end

    test "emits exception event on raise" do
      self = self()

      :telemetry.attach(
        "test-span-exception",
        [:minga, :test, :raise, :exception],
        fn event, measurements, metadata, _config ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      assert_raise RuntimeError, fn ->
        Telemetry.span([:minga, :test, :raise], %{}, fn -> raise "boom" end)
      end

      assert_received {:telemetry, [:minga, :test, :raise, :exception], %{duration: _},
                       %{kind: :error, reason: %RuntimeError{}, stacktrace: _}}
    after
      :telemetry.detach("test-span-exception")
    end

    test "passes metadata through to events" do
      self = self()

      :telemetry.attach(
        "test-span-metadata",
        [:minga, :test, :meta, :stop],
        fn _event, _measurements, metadata, _config ->
          send(self, {:metadata, metadata})
        end,
        nil
      )

      Telemetry.span([:minga, :test, :meta], %{stage: :content, window_count: 2}, fn -> :ok end)

      assert_received {:metadata, %{stage: :content, window_count: 2}}
    after
      :telemetry.detach("test-span-metadata")
    end
  end

  describe "execute/3" do
    test "emits a single event with measurements and metadata" do
      self = self()

      :telemetry.attach(
        "test-execute",
        [:minga, :test, :point],
        fn event, measurements, metadata, _config ->
          send(self, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.execute([:minga, :test, :point], %{byte_count: 4096}, %{source: :emit})

      assert_received {:telemetry, [:minga, :test, :point], %{byte_count: 4096}, %{source: :emit}}
    after
      :telemetry.detach("test-execute")
    end
  end
end
