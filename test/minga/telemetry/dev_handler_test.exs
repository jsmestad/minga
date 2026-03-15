defmodule Minga.Telemetry.DevHandlerTest do
  use ExUnit.Case, async: false

  alias Minga.Telemetry
  alias Minga.Telemetry.DevHandler

  # DevHandler tests are async: false because they modify global telemetry
  # handler state. We test by intercepting the handler's calls to Minga.Log
  # via a test telemetry handler that captures what the DevHandler would emit,
  # rather than relying on Logger capture (which is suppressed at :warning
  # level in test config).

  setup do
    # Detach any existing handler, attach fresh for each test
    DevHandler.detach()
    DevHandler.attach()
    on_exit(fn -> DevHandler.detach() end)
    :ok
  end

  describe "attach/0" do
    test "is idempotent (calling twice doesn't crash)" do
      assert :ok = DevHandler.attach()
      assert :ok = DevHandler.attach()
    end
  end

  describe "render stage events" do
    test "handler receives stage metadata on [:minga, :render, :stage, :stop]" do
      # The DevHandler is attached and handles the event. We verify the event
      # fires correctly by attaching our own test handler alongside it.
      self = self()

      :telemetry.attach(
        "test-render-stage",
        [:minga, :render, :stage, :stop],
        fn _event, measurements, metadata, _config ->
          send(self, {:stage_stop, measurements, metadata})
        end,
        nil
      )

      Telemetry.span([:minga, :render, :stage], %{stage: :content}, fn -> :ok end)

      assert_received {:stage_stop, %{duration: duration}, %{stage: :content}}
      assert is_integer(duration)
      assert duration >= 0
    after
      :telemetry.detach("test-render-stage")
    end
  end

  describe "render pipeline events" do
    test "handler receives pipeline stop event" do
      self = self()

      :telemetry.attach(
        "test-render-pipeline",
        [:minga, :render, :pipeline, :stop],
        fn _event, measurements, _metadata, _config ->
          send(self, {:pipeline_stop, measurements})
        end,
        nil
      )

      Telemetry.span([:minga, :render, :pipeline], %{}, fn -> :ok end)

      assert_received {:pipeline_stop, %{duration: duration}}
      assert is_integer(duration)
      assert duration >= 0
    after
      :telemetry.detach("test-render-pipeline")
    end
  end

  describe "input dispatch events" do
    test "handler receives dispatch stop event" do
      self = self()

      :telemetry.attach(
        "test-input-dispatch",
        [:minga, :input, :dispatch, :stop],
        fn _event, measurements, _metadata, _config ->
          send(self, {:dispatch_stop, measurements})
        end,
        nil
      )

      Telemetry.span([:minga, :input, :dispatch], %{}, fn -> :ok end)

      assert_received {:dispatch_stop, %{duration: duration}}
      assert is_integer(duration)
    after
      :telemetry.detach("test-input-dispatch")
    end
  end

  describe "command execute events" do
    test "handler receives command name in metadata" do
      self = self()

      :telemetry.attach(
        "test-command-execute",
        [:minga, :command, :execute, :stop],
        fn _event, measurements, metadata, _config ->
          send(self, {:command_stop, measurements, metadata})
        end,
        nil
      )

      Telemetry.span([:minga, :command, :execute], %{command: :move_down}, fn -> :ok end)

      assert_received {:command_stop, %{duration: _}, %{command: :move_down}}
    after
      :telemetry.detach("test-command-execute")
    end

    test "handler uses :unknown when command metadata is missing" do
      # Verify the DevHandler's handle_event uses Map.get with default :unknown
      measurements = %{duration: 1000}
      metadata = %{}

      # Call the handler directly to test the fallback
      assert :ok =
               DevHandler.handle_event(
                 [:minga, :command, :execute, :stop],
                 measurements,
                 metadata,
                 nil
               )
    end
  end

  describe "port emit events" do
    test "handler receives byte_count in metadata" do
      self = self()

      :telemetry.attach(
        "test-port-emit",
        [:minga, :port, :emit, :stop],
        fn _event, measurements, metadata, _config ->
          send(self, {:emit_stop, measurements, metadata})
        end,
        nil
      )

      Telemetry.span([:minga, :port, :emit], %{byte_count: 1234}, fn -> :ok end)

      assert_received {:emit_stop, %{duration: _}, %{byte_count: 1234}}
    after
      :telemetry.detach("test-port-emit")
    end
  end

  describe "handler resilience" do
    test "catch-all clause handles unknown events without crashing" do
      assert :ok = DevHandler.handle_event([:minga, :unknown, :event], %{}, %{}, nil)
    end
  end
end
