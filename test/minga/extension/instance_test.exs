defmodule Minga.Extension.InstanceTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Entry
  alias Minga.Extension.Instance.Artifact
  alias Minga.Extension.Instance.Projection
  alias Minga.Extension.Instance.Runtime
  alias Minga.Extension.Instance.State
  alias Minga.Extension.Manifest
  alias Minga.Extension.Registry

  test "state strips lifecycle projection from declaration identity" do
    declaration = %Entry{
      source_type: :path,
      path: "/tmp/example",
      module: Some.Projected.Module,
      pid: self(),
      status: :running,
      last_error: :stale
    }

    state = State.new(:example, declaration, :registry, :instances, [])
    assert state.phase == :stopped
    assert state.declaration.module == nil
    assert state.declaration.pid == nil
    assert state.declaration.status == :stopped
    assert state.declaration.last_error == nil
  end

  test "projection is the compatible view of tagged phases" do
    registry = :"instance_projection_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: registry})
    :ok = Registry.register(registry, :projection, "/tmp/projection", [])
    {:ok, declaration} = Registry.get(registry, :projection)
    state = State.new(:projection, declaration, registry, :instances, [])

    :ok = Projection.publish(state)
    assert {:ok, %{status: :stopped, pid: nil}} = Registry.get(registry, :projection)

    runtime = spawn(fn -> receive do: (:stop -> :ok) end)
    running = State.running(state, Runtime.monitor(runtime))
    :ok = Projection.publish(running)
    assert {:ok, %{status: :running, pid: ^runtime}} = Registry.get(registry, :projection)

    send(runtime, :stop)
  end

  test "projection fails when its registry declaration is absent" do
    registry = :"missing_projection_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: registry})

    declaration = %Entry{source_type: :module, module: __MODULE__.RestartFixture}
    state = State.new(:missing_projection, declaration, registry, :instances, [])

    assert {:error, {:extension_not_declared, :missing_projection}} = Projection.publish(state)
  end

  test "declaration replaces request overrides and preserves stable collaborators" do
    declaration = %Entry{source_type: :module, module: __MODULE__.RestartFixture}

    state =
      State.new(:collaborators, declaration, :registry, :instances,
        command_registry: :commands,
        artifact_admission: self(),
        transition_timeout_ms: 25,
        callbacks: %{cleanup: fn _source -> :ok end}
      )

    assert {:ok, declared} =
             State.declare(state, declaration, :current_registry, runtime_query_timeout_ms: 500)

    assert declared.registry == :current_registry
    assert declared.collaborators[:command_registry] == :commands
    assert declared.collaborators[:artifact_admission] == self()
    assert declared.collaborators[:runtime_query_timeout_ms] == 500
    refute Keyword.has_key?(declared.collaborators, :transition_timeout_ms)
    refute Keyword.has_key?(declared.collaborators, :callbacks)

    configured = State.configure(declared, [])
    assert configured.collaborators[:command_registry] == :commands
    assert configured.collaborators[:artifact_admission] == self()
    refute Keyword.has_key?(configured.collaborators, :runtime_query_timeout_ms)
  end

  test "artifact preserves declared restart policy and forces runtime temporary" do
    manifest = %Manifest{
      name: :artifact,
      description: "artifact",
      version: "1.0.0",
      source: :module,
      commands: [],
      keybindings: [],
      modeline_segments: [],
      capabilities: [],
      load_policy: :eager
    }

    module = __MODULE__.RestartFixture
    assert {:ok, artifact} = Artifact.build(:artifact, module, manifest, [module], [])

    assert artifact.restart == :transient
    assert artifact.child_spec.restart == :temporary
  end

  defmodule RestartFixture do
    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(_opts) do
      %{
        id: __MODULE__,
        start: {Agent, :start_link, [fn -> :ok end]},
        restart: :transient,
        type: :worker
      }
    end
  end
end
