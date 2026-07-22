defmodule MingaEditor.Handlers.BufferOpenedEventFlowTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Events
  alias MingaEditor.Commands
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.Handlers.GuiActionHandler
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State.ExtensionSurfaces

  @moduletag :tmp_dir

  describe "foreground buffer-open event flow" do
    test "BufferRegistry foreground open emits one creation event and no registration event", %{
      tmp_dir: tmp_dir
    } do
      Events.subscribe(:buffer_opened)
      path = write_file!(tmp_dir, "registry-open.txt")

      assert {:ok, state} = BufferRegistry.open_file_by_path_result(base_state(), path)
      assert [pid] = Enum.filter(state.workspace.buffers.list, &(Buffer.file_path(&1) == path))

      assert_receive {:minga_event, :buffer_opened,
                      %Events.BufferEvent{buffer: ^pid, path: ^path}}

      refute_receive {:minga_event, :buffer_opened,
                      %Events.BufferEvent{buffer: ^pid, path: ^path}},
                     50
    end

    test "GUI foreground open emits one creation event and no registration event", %{
      tmp_dir: tmp_dir
    } do
      Events.subscribe(:buffer_opened)
      path = write_file!(tmp_dir, "gui-open.txt")

      state = GuiActionHandler.dispatch(base_state(), {:open_file, path})
      assert [pid] = Enum.filter(state.workspace.buffers.list, &(Buffer.file_path(&1) == path))

      assert_receive {:minga_event, :buffer_opened,
                      %Events.BufferEvent{buffer: ^pid, path: ^path}}

      refute_receive {:minga_event, :buffer_opened,
                      %Events.BufferEvent{buffer: ^pid, path: ^path}},
                     50
    end

    test "existing-buffer foreground registration emits no buffer_opened event", %{
      tmp_dir: tmp_dir
    } do
      registry = start_events_registry()
      :ok = Events.subscribe(:buffer_opened, registry)
      path = write_file!(tmp_dir, "existing.txt")

      assert {:ok, pid} = Commands.start_buffer(path, nil, events_registry: registry)

      assert_receive {:minga_event, :buffer_opened,
                      %Events.BufferEvent{buffer: ^pid, path: ^path}}

      assert {:ok, state} = BufferRegistry.open_file_by_path_result(base_state(registry), path)
      assert pid in state.workspace.buffers.list

      refute_receive {:minga_event, :buffer_opened,
                      %Events.BufferEvent{buffer: ^pid, path: ^path}},
                     50
    end

    test "foreground open error emits no buffer_opened event", %{tmp_dir: tmp_dir} do
      Events.subscribe(:buffer_opened)
      missing_path = Path.join(tmp_dir, "missing.txt") |> Path.expand()

      assert {:error, :enoent} =
               BufferRegistry.open_file_by_path_result(base_state(), missing_path)

      refute_receive {:minga_event, :buffer_opened, %Events.BufferEvent{path: ^missing_path}}, 50
    end
  end

  test "foreground creation uses the editor's private event registry", %{tmp_dir: tmp_dir} do
    registry = start_events_registry()
    parent = self()

    default_observer =
      spawn(fn ->
        :ok = Events.subscribe(:buffer_opened)
        send(parent, {:default_registry_ready, self()})

        receive do
          {:minga_event, :buffer_opened, event} ->
            send(parent, {:default_registry_event, event})

          :assert_quiet ->
            send(parent, {:default_registry_quiet, self()})
        end
      end)

    assert_receive {:default_registry_ready, ^default_observer}
    :ok = Events.subscribe(:buffer_opened, registry)
    path = write_file!(tmp_dir, "private-registry.txt")

    assert {:ok, state} = BufferRegistry.open_file_by_path_result(base_state(registry), path)
    assert [pid] = Enum.filter(state.workspace.buffers.list, &(Buffer.file_path(&1) == path))

    assert_receive {:minga_event, :buffer_opened, %Events.BufferEvent{buffer: ^pid, path: ^path}}
    send(default_observer, :assert_quiet)

    assert_receive {:default_registry_quiet, ^default_observer}

    refute_receive {:default_registry_event, %Events.BufferEvent{buffer: ^pid, path: ^path}}
  end

  defp base_state(events_registry \\ Events.default_registry()) do
    state = TestHelpers.base_state()

    %{
      state
      | extension_surfaces:
          ExtensionSurfaces.install_events_registry(state.extension_surfaces, events_registry)
    }
  end

  defp write_file!(tmp_dir, name) do
    path = Path.join(tmp_dir, name) |> Path.expand()
    File.write!(path, "hello")
    path
  end

  defp start_events_registry do
    name = :"buffer_opened_event_flow_#{System.unique_integer([:positive])}"
    start_supervised!({Events, name: name})
    name
  end
end
