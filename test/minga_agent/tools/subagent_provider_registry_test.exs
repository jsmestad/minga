defmodule MingaAgent.Tools.SubagentProviderRegistryTest do
  # Mutates global ProviderRegistry/source state, so these tests must run serially.
  use ExUnit.Case, async: false

  alias MingaAgent.ProviderPacks.Native, as: NativeProviderPack
  alias MingaAgent.ProviderRegistry
  alias MingaAgent.Tools.Subagent
  alias Minga.Test.SubagentGatedProvider, as: GatedProvider
  alias Minga.Test.SubagentRecordingProvider, as: RecordingProvider

  @moduletag :tmp_dir

  test "foreground subagent resolves registered string provider ids" do
    test_pid = self()

    assert :ok =
             ProviderRegistry.register(
               id: "gated-test",
               source: :config,
               module: GatedProvider,
               display_name: "Gated Test"
             )

    on_exit(fn -> ProviderRegistry.unregister_source(:config) end)

    task =
      Task.async(fn ->
        Subagent.execute("registered provider task",
          provider: "gated-test",
          provider_opts: [test_pid: test_pid]
        )
      end)

    assert_receive {:provider_prompt, provider_pid, "registered provider task"}, 1_000
    assert :ok = GatedProvider.proceed(provider_pid, "registered done")
    assert {:ok, "registered done"} = Task.await(task)
  end

  test "native provider atom override is rejected when the bundled source is disabled" do
    assert :ok = ProviderRegistry.disable("native")
    on_exit(fn -> ProviderRegistry.enable("native") end)

    assert {:error, message} = Subagent.execute("blocked native", provider: :native)
    assert message =~ "Failed to resolve subagent provider"
    assert message =~ ":disabled"
  end

  test "native provider string override is rejected when the bundled source is disabled" do
    assert :ok = ProviderRegistry.disable("native")
    on_exit(fn -> ProviderRegistry.enable("native") end)

    assert {:error, message} = Subagent.execute("blocked native", provider: "native")
    assert message =~ "Failed to resolve subagent provider"
    assert message =~ ":disabled"
  end

  test "default native provider is rejected after bundled source cleanup" do
    assert :ok = ProviderRegistry.unregister_source(NativeProviderPack.source())
    on_exit(fn -> NativeProviderPack.register() end)

    assert {:error, message} = Subagent.execute("blocked native")
    assert message =~ "Failed to resolve subagent provider"
    assert message =~ ":not_found"
  end

  test "inherited source-owned providers resolve for child sessions while registered", %{
    tmp_dir: dir
  } do
    source = {:bundle, :recording_subagent_provider_positive}
    provider_id = "recording-subagent-provider-positive"
    ref = make_ref()

    assert :ok =
             ProviderRegistry.register(
               id: provider_id,
               source: source,
               module: RecordingProvider,
               display_name: "Recording Subagent Provider"
             )

    {:ok, parent} =
      MingaAgent.Supervisor.start_session(
        provider: RecordingProvider,
        provider_id: provider_id,
        provider_source: source,
        model_name: "parent-model",
        provider_opts: [
          provider: "recording",
          model: "parent-model",
          thinking_level: "high",
          active_skill_names: ["elixir"],
          project_root: dir,
          test_pid: self(),
          test_ref: ref
        ]
      )

    assert_receive {^ref, {:provider_started, _provider_pid, _opts}}, 1_000

    on_exit(fn ->
      MingaAgent.Supervisor.stop_session(parent)
      ProviderRegistry.unregister_source(source)
    end)

    assert {:ok, "child response"} =
             Subagent.execute("allowed inherited",
               parent_session: parent,
               project_root: dir,
               provider_opts: [test_pid: self(), test_ref: ref]
             )

    assert_receive {^ref, {:provider_started, _child_provider, child_opts}}, 1_000
    assert Keyword.fetch!(child_opts, :project_root) == dir
    assert Keyword.fetch!(child_opts, :provider) == provider_id
    assert Keyword.fetch!(child_opts, :model) == "parent-model"
    assert Keyword.fetch!(child_opts, :thinking_level) == "high"
    assert Keyword.fetch!(child_opts, :active_skill_names) == ["elixir"]
    assert Keyword.fetch!(child_opts, :test_ref) == ref

    assert_receive {^ref, {:prompt_received, _provider_pid, _subscriber, "allowed inherited"}},
                   1_000
  end

  test "inherited source-owned providers are rechecked for child sessions", %{tmp_dir: dir} do
    source = {:bundle, :recording_subagent_provider}
    provider_id = "recording-subagent-provider"
    ref = make_ref()

    assert :ok =
             ProviderRegistry.register(
               id: provider_id,
               source: source,
               module: RecordingProvider,
               display_name: "Recording Subagent Provider"
             )

    {:ok, parent} =
      MingaAgent.Supervisor.start_session(
        provider: RecordingProvider,
        provider_id: provider_id,
        provider_source: source,
        model_name: "parent-model",
        provider_opts: [
          provider: "recording",
          model: "parent-model",
          project_root: dir,
          test_pid: self(),
          test_ref: ref
        ]
      )

    assert_receive {^ref, {:provider_started, _provider_pid, _opts}}, 1_000
    assert :ok = ProviderRegistry.unregister_source(source)

    on_exit(fn ->
      MingaAgent.Supervisor.stop_session(parent)
      ProviderRegistry.unregister_source(source)
    end)

    assert {:error, message} =
             Subagent.execute("blocked inherited", parent_session: parent, project_root: dir)

    assert message =~ "Failed to resolve subagent provider"
    assert message =~ ":not_found"
  end
end
