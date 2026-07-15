defmodule Minga.Extension.ArtifactGenerationStateTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.ArtifactGenerationState

  test "owner restart rehydrates a fresh generation snapshot" do
    {owner, name} = start_owner(:fresh)
    fresh = %{sources: %{}, module_sources: %{}, sealed?: false, failed?: false}
    assert :ok = ArtifactGenerationState.store(owner, fresh)

    restarted = restart_owner(owner, name)
    assert {:ok, ^fresh} = ArtifactGenerationState.fetch(restarted)
  end

  test "owner restart rehydrates sealing" do
    {owner, name} = start_owner(:sealed)
    sealed = %{sources: %{}, module_sources: %{}, sealed?: true, failed?: false}
    assert :ok = ArtifactGenerationState.store(owner, sealed)

    restarted = restart_owner(owner, name)
    assert {:ok, ^sealed} = ArtifactGenerationState.fetch(restarted)
  end

  test "owner restart rehydrates committed source and module provenance" do
    {owner, name} = start_owner(:committed)
    source = {:extension, unique_name(:committed_source)}
    module = unique_module("Committed")
    record = source_record(module, :committed)

    snapshot = %{
      sources: %{source => record},
      module_sources: %{module => source},
      sealed?: true,
      failed?: false
    }

    assert :ok = ArtifactGenerationState.store(owner, snapshot)
    restarted = restart_owner(owner, name)
    assert {:ok, ^snapshot} = ArtifactGenerationState.fetch(restarted)
  end

  test "claimed attempts persist without live pending authority" do
    {owner, name} = start_owner(:claimed)
    source = {:extension, unique_name(:claimed_source)}
    module = unique_module("Claimed")

    assert :ok = ArtifactGenerationState.store(owner, pending_snapshot(source, module, :claimed))
    restarted = restart_owner(owner, name)
    assert {:ok, snapshot} = ArtifactGenerationState.fetch(restarted)
    assert snapshot.sources[source].status == {:pending, :claimed}
    refute contains_live_authority?(snapshot)
  end

  test "loading attempts persist possibly-loaded provenance without live authority" do
    {owner, name} = start_owner(:loading)
    source = {:extension, unique_name(:loading_source)}
    module = unique_module("Loading")

    assert :ok = ArtifactGenerationState.store(owner, pending_snapshot(source, module, :loading))
    restarted = restart_owner(owner, name)
    assert {:ok, snapshot} = ArtifactGenerationState.fetch(restarted)
    assert snapshot.sources[source].status == {:pending, :loading}
    assert snapshot.module_sources[module] == source
    refute contains_live_authority?(snapshot)
  end

  test "owner restart preserves globally failed status and failed provenance" do
    {owner, name} = start_owner(:failed)
    source = {:extension, unique_name(:failed_source)}
    module = unique_module("Failed")
    record = source_record(module, :failed)

    failed = %{
      sources: %{source => record},
      module_sources: %{module => source},
      sealed?: false,
      failed?: true
    }

    assert :ok = ArtifactGenerationState.store(owner, failed)
    restarted = restart_owner(owner, name)
    assert {:ok, ^failed} = ArtifactGenerationState.fetch(restarted)
  end

  test "the test reset API refuses the production persistence key" do
    assert {:error, :production_persistence_key} =
             ArtifactGenerationState.reset_for_test(:production)
  end

  defp start_owner(prefix) do
    name = unique_name(prefix)
    persistence_key = {__MODULE__, prefix, make_ref()}

    owner =
      start_supervised!(
        {ArtifactGenerationState, name: name, persistence_key: persistence_key},
        id: unique_name(:generation_state_child)
      )

    on_exit(fn ->
      assert :ok = ArtifactGenerationState.reset_for_test(persistence_key)
    end)

    {owner, name}
  end

  defp restart_owner(owner, name) do
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1_000
    await_registered_restart(name, owner, 1_000)
  end

  defp await_registered_restart(name, old_pid, remaining) when remaining > 0 do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _other ->
        receive do
        after
          10 -> await_registered_restart(name, old_pid, remaining - 10)
        end
    end
  end

  defp await_registered_restart(name, _old_pid, 0) do
    flunk("#{inspect(name)} did not restart")
  end

  defp pending_snapshot(source, module, phase) do
    pending = %{
      token: make_ref(),
      owner: self(),
      owner_monitor: make_ref(),
      phase: phase,
      waiters: [
        %{from: {self(), make_ref()}, pid: self(), monitor: make_ref()}
      ]
    }

    %{
      sources: %{source => source_record(module, {:pending, pending})},
      module_sources: %{module => source},
      sealed?: false,
      failed?: false
    }
  end

  defp source_record(module, status) do
    fingerprint = :crypto.hash(:sha256, Atom.to_string(module))

    %{
      fingerprint: fingerprint,
      source_fingerprint: fingerprint,
      modules: [module],
      load_modules: [module],
      adopted_modules: [],
      status: status
    }
  end

  defp contains_live_authority?(term) when is_pid(term) or is_reference(term), do: true

  defp contains_live_authority?(term) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      contains_live_authority?(key) or contains_live_authority?(value)
    end)
  end

  defp contains_live_authority?(term) when is_list(term),
    do: Enum.any?(term, &contains_live_authority?/1)

  defp contains_live_authority?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_live_authority?/1)

  defp contains_live_authority?(_term), do: false

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

  defp unique_module(suffix),
    do: Module.concat(["GenerationState#{suffix}#{System.unique_integer([:positive])}"])
end
