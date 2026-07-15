defmodule Minga.Extension.ArtifactAdmissionTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState

  @event_timeout 5_000

  setup do
    {_owner, owner_name, _persistence_key} = start_isolated_owner(:admission_owner)

    admission =
      start_supervised!(
        {ArtifactAdmission, name: nil, state_owner: owner_name},
        id: unique_name(:private_admission)
      )

    %{admission: admission}
  end

  test "claims a complete source set atomically and reports it deterministically", %{
    admission: admission
  } do
    source = {:extension, unique_name(:owner)}
    modules = [unique_module("Second"), unique_module("First")]
    fingerprint = :crypto.hash(:sha256, "one-generation")

    assert {:ok, claim} =
             ArtifactAdmission.claim_source_modules(source, modules, fingerprint,
               server: admission
             )

    assert claim.acquired?
    assert claim.modules == Enum.sort(modules)
    assert claim.load_modules == Enum.sort(modules)
    assert claim.adopted_modules == []
    assert :ok = ArtifactAdmission.commit_attempt(claim, server: admission)

    assert ArtifactAdmission.source_modules(source, server: admission) ==
             {:ok, Enum.sort(modules)}
  end

  test "a mixed cross-source set fails without claiming any member", %{admission: admission} do
    first = {:extension, unique_name(:first)}
    second = {:extension, unique_name(:second)}
    owned = unique_module("Owned")
    free = unique_module("Free")

    assert {:ok, _claim} = claim(admission, first, [owned], "first")

    assert {:error, {:module_owned_by_source, ^owned, ^first, ^second}} =
             claim(admission, second, [free, owned], "second")

    assert :error = ArtifactAdmission.source_modules(second, server: admission)

    third = {:extension, unique_name(:third)}
    assert {:ok, _claim} = claim(admission, third, [free], "third")
  end

  test "host code-path modules collide before a source record exists", %{admission: admission} do
    source = {:extension, unique_name(:host_collision)}

    assert {:error, {:module_conflicts_with_host, Minga.Buffer}} =
             claim(admission, source, [Minga.Buffer], "host")

    assert :error = ArtifactAdmission.source_modules(source, server: admission)
  end

  test "verified application modules are adopted atomically with unloaded outputs", %{
    admission: admission
  } do
    source = {:extension, unique_name(:trusted)}
    generated = unique_module("Generated")

    assert {:ok, claim} =
             ArtifactAdmission.claim_source_modules(
               source,
               [Minga.Buffer, generated],
               :crypto.hash(:sha256, "trusted"),
               server: admission,
               trusted_application: :minga
             )

    assert claim.adopted_modules == [Minga.Buffer]
    assert claim.load_modules == [generated]

    other_source = {:extension, unique_name(:other_trusted)}
    other_generated = unique_module("OtherGenerated")

    assert {:ok, other_claim} =
             ArtifactAdmission.claim_source_modules(
               other_source,
               [Minga.Buffer, other_generated],
               :crypto.hash(:sha256, "other-trusted"),
               server: admission,
               trusted_application: :minga
             )

    assert other_claim.adopted_modules == [Minga.Buffer]
    assert other_claim.load_modules == [other_generated]
  end

  test "exclusive trusted adoption preserves source collisions and releases aborted claims", %{
    admission: admission
  } do
    owner = {:extension, unique_name(:exclusive_owner)}
    candidate = {:extension, unique_name(:exclusive_candidate)}
    fingerprint = :crypto.hash(:sha256, "exclusive-owner")

    assert {:ok, owner_claim} =
             ArtifactAdmission.claim_source_modules(owner, [Minga.Buffer], fingerprint,
               server: admission,
               trusted_application: :minga,
               exclusive_adoption: true
             )

    assert {:error, {:module_owned_by_source, Minga.Buffer, ^owner, ^candidate}} =
             ArtifactAdmission.claim_source_modules(
               candidate,
               [Minga.Buffer],
               :crypto.hash(:sha256, "exclusive-candidate"),
               server: admission,
               trusted_application: :minga,
               exclusive_adoption: true
             )

    assert :ok = ArtifactAdmission.abort_attempt(owner_claim, server: admission)

    assert {:ok, _candidate_claim} =
             ArtifactAdmission.claim_source_modules(
               candidate,
               [Minga.Buffer],
               :crypto.hash(:sha256, "exclusive-candidate"),
               server: admission,
               trusted_application: :minga,
               exclusive_adoption: true
             )
  end

  test "mixed trusted adoption collision is atomic", %{admission: admission} do
    owner = {:extension, unique_name(:mixed_owner)}
    candidate = {:extension, unique_name(:mixed_candidate)}
    generated = unique_module("MixedGenerated")
    assert {:ok, owner_claim} = claim(admission, owner, [generated], "mixed-owner")
    assert :ok = ArtifactAdmission.commit_attempt(owner_claim, server: admission)

    assert {:error, {:module_owned_by_source, ^generated, ^owner, ^candidate}} =
             ArtifactAdmission.claim_source_modules(
               candidate,
               [Minga.Buffer, generated],
               :crypto.hash(:sha256, "mixed-candidate"),
               server: admission,
               trusted_application: :minga
             )

    assert :error = ArtifactAdmission.source_modules(candidate, server: admission)
    refute function_exported?(Minga.Buffer, :hostile, 0)
  end

  test "invalid and oversized deterministic module sets never reach the authority", %{
    admission: admission
  } do
    source = {:extension, unique_name(:hostile_set)}
    fingerprint = :crypto.hash(:sha256, "hostile-set")

    assert {:error, {:invalid_module_set, []}} =
             ArtifactAdmission.claim_source_modules(source, [], fingerprint, server: admission)

    assert {:error, {:invalid_module_set, [:valid, "not-an-atom"]}} =
             ArtifactAdmission.claim_source_modules(source, [:valid, "not-an-atom"], fingerprint,
               server: admission
             )

    modules = List.duplicate(Minga.Buffer, 129)

    assert {:error, {:invalid_module_set, ^modules}} =
             ArtifactAdmission.claim_source_modules(source, modules, fingerprint,
               server: admission
             )

    assert :error = ArtifactAdmission.source_modules(source, server: admission)
  end

  test "sealing preserves admitted sources and rejects first-time activation", %{
    admission: admission
  } do
    admitted_source = {:extension, unique_name(:admitted_before_seal)}
    admitted_module = unique_module("AdmittedBeforeSeal")

    assert {:ok, admitted_claim} =
             claim(admission, admitted_source, [admitted_module], "before-seal")

    assert :ok = ArtifactAdmission.commit_attempt(admitted_claim, server: admission)
    assert :ok = ArtifactAdmission.seal(server: admission)

    assert {:ok, existing} =
             claim(admission, admitted_source, [admitted_module], "before-seal")

    refute existing.acquired?

    new_source = {:extension, unique_name(:after_seal)}
    new_module = unique_module("AfterSeal")

    assert {:error, {:generation_sealed, ^new_source}} =
             claim(admission, new_source, [new_module], "after-seal")

    assert :error = ArtifactAdmission.source_modules(new_source, server: admission)
  end

  test "commit reports admission unavailability for acquired and idempotent claims", %{
    admission: admission
  } do
    source = {:extension, unique_name(:unavailable_commit)}
    module = unique_module("UnavailableCommit")
    assert {:ok, acquired} = claim(admission, source, [module], "unavailable-commit")
    assert :ok = ArtifactAdmission.commit_attempt(acquired, server: admission)
    assert {:ok, shared} = claim(admission, source, [module], "unavailable-commit")
    refute shared.acquired?

    monitor = Process.monitor(admission)
    GenServer.stop(admission, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^admission, :normal}, 1_000

    assert {:error, {:artifact_admission_unavailable, ^admission}} =
             ArtifactAdmission.commit_attempt(acquired, server: admission)

    assert {:error, {:artifact_admission_unavailable, ^admission}} =
             ArtifactAdmission.commit_attempt(shared, server: admission)
  end

  test "changed artifacts for one source require a fresh VM generation", %{admission: admission} do
    source = {:extension, unique_name(:generation)}
    module = unique_module("Generation")

    assert {:ok, first} = claim(admission, source, [module], "one")
    assert first.acquired?
    assert :ok = ArtifactAdmission.commit_attempt(first, server: admission)
    assert {:ok, same} = claim(admission, source, [module], "one")
    refute same.acquired?
    assert :ok = ArtifactAdmission.abort_attempt(same, server: admission)
    assert {:ok, [^module]} = ArtifactAdmission.source_modules(source, server: admission)

    assert {:error, {:source_artifact_changed, ^source}} =
             claim(admission, source, [module], "two")
  end

  test "failed-attempt release removes only the claim acquired by that attempt", %{
    admission: admission
  } do
    source = {:extension, unique_name(:rollback)}
    module = unique_module("Rollback")
    assert {:ok, claim} = claim(admission, source, [module], "rollback")

    assert :ok = ArtifactAdmission.abort_attempt(claim, server: admission)
    assert :error = ArtifactAdmission.source_modules(source, server: admission)

    other = {:extension, unique_name(:other)}
    assert {:ok, _claim} = claim(admission, other, [module], "other")
  end

  test "same-artifact callers wait for commit and cannot release the owner's claim", %{
    admission: admission
  } do
    source = {:extension, unique_name(:serialized)}
    module = unique_module("Serialized")
    assert {:ok, owner} = claim(admission, source, [module], "serialized")

    waiter = Task.async(fn -> claim(admission, source, [module], "serialized") end)
    assert Task.yield(waiter, 20) == nil

    assert :ok = ArtifactAdmission.commit_attempt(owner, server: admission)
    assert {:ok, {:ok, shared}} = Task.yield(waiter, 1_000)
    refute shared.acquired?
    assert :ok = ArtifactAdmission.abort_attempt(shared, server: admission)
    assert {:ok, [^module]} = ArtifactAdmission.source_modules(source, server: admission)
  end

  test "abort transfers a unique attempt token to the next equivalent caller", %{
    admission: admission
  } do
    source = {:extension, unique_name(:transfer)}
    module = unique_module("Transfer")
    assert {:ok, first} = claim(admission, source, [module], "transfer")

    waiter = Task.async(fn -> claim(admission, source, [module], "transfer") end)
    assert Task.yield(waiter, 20) == nil
    assert :ok = ArtifactAdmission.abort_attempt(first, server: admission)
    assert {:ok, {:ok, second}} = Task.yield(waiter, 1_000)
    assert second.acquired?
    refute second.attempt_token == first.attempt_token
    assert :ok = ArtifactAdmission.commit_attempt(second, server: admission)
  end

  test "owner death before loading transfers to a verified live waiter with a fresh token", %{
    admission: admission
  } do
    source = {:extension, unique_name(:owner_death_transfer)}
    module = unique_module("OwnerDeathTransfer")
    parent = self()

    owner =
      spawn(fn ->
        result = claim(admission, source, [module], "owner-death-transfer")
        send(parent, {:owner_claim, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:owner_claim, ^owner, {:ok, first}}, 1_000

    waiter =
      spawn(fn ->
        result = claim(admission, source, [module], "owner-death-transfer")
        send(parent, {:transferred_claim, self(), result})

        receive do
          {:commit, claim} ->
            send(
              parent,
              {:transferred_commit, ArtifactAdmission.commit_attempt(claim, server: admission)}
            )
        end
      end)

    refute_receive {:transferred_claim, ^waiter, _result}, 20
    assert await_waiter_count(admission, source, 1, 1_000)

    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, @event_timeout
    assert_receive {:transferred_claim, ^waiter, {:ok, transferred}}, @event_timeout
    assert transferred.acquired?
    assert transferred.attempt_token != first.attempt_token
    send(waiter, {:commit, transferred})
    assert_receive {:transferred_commit, :ok}, @event_timeout
    assert {:ok, [^module]} = ArtifactAdmission.source_modules(source, server: admission)
  end

  test "owner death before loading without a waiter releases authority without blocking", %{
    admission: admission
  } do
    source = {:extension, unique_name(:owner_death_release)}
    module = unique_module("OwnerDeathRelease")
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:owner_claim, self(), claim(admission, source, [module], "owner-release")})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:owner_claim, ^owner, {:ok, abandoned}}, 1_000
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, @event_timeout
    _ = :sys.get_state(admission)

    assert :ok = ArtifactAdmission.abort_attempt(abandoned, server: admission)
    assert {:ok, replacement} = claim(admission, source, [module], "owner-release")
    assert replacement.acquired?
    assert replacement.attempt_token != abandoned.attempt_token
    assert :ok = ArtifactAdmission.abort_attempt(replacement, server: admission)
  end

  test "dead waiters are removed and never receive transferred authority", %{admission: admission} do
    source = {:extension, unique_name(:dead_waiter)}
    module = unique_module("DeadWaiter")
    assert {:ok, owner} = claim(admission, source, [module], "dead-waiter")
    parent = self()

    waiter =
      spawn(fn ->
        send(parent, {:waiter_started, self()})
        _ = claim(admission, source, [module], "dead-waiter")
      end)

    assert_receive {:waiter_started, ^waiter}, @event_timeout
    assert await_waiter_count(admission, source, 1, 1_000)
    waiter_monitor = Process.monitor(waiter)
    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^waiter_monitor, :process, ^waiter, :killed}, @event_timeout
    _ = :sys.get_state(admission)

    assert :ok = ArtifactAdmission.abort_attempt(owner, server: admission)
    assert {:ok, replacement} = claim(admission, source, [module], "dead-waiter")
    assert replacement.acquired?
    assert :ok = ArtifactAdmission.abort_attempt(replacement, server: admission)
  end

  test "owner death after loading fails every source and preserves all provenance", %{
    admission: admission
  } do
    committed_source = {:extension, unique_name(:committed_before_failure)}
    committed_module = unique_module("CommittedBeforeFailure")

    assert {:ok, committed_claim} =
             claim(admission, committed_source, [committed_module], "committed")

    assert :ok = ArtifactAdmission.commit_attempt(committed_claim, server: admission)

    assert {:ok, shared_committed_claim} =
             claim(admission, committed_source, [committed_module], "committed")

    refute shared_committed_claim.acquired?

    loading_source = {:extension, unique_name(:owner_death_after_load)}
    loading_module = unique_module("OwnerDeathAfterLoad")
    pending_source = {:extension, unique_name(:pending_during_failure)}
    pending_module = unique_module("PendingDuringFailure")
    parent = self()

    loading_owner =
      spawn(fn ->
        {:ok, loading_claim} =
          claim(admission, loading_source, [loading_module], "owner-after-load")

        :ok = ArtifactAdmission.mark_loading(loading_claim, server: admission)
        send(parent, {:loading_claim, self(), loading_claim})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:loading_claim, ^loading_owner, loading_claim}, 1_000

    pending_owner =
      spawn(fn ->
        {:ok, pending_claim} = claim(admission, pending_source, [pending_module], "pending")
        send(parent, {:pending_claim, self(), pending_claim})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:pending_claim, ^pending_owner, pending_claim}, @event_timeout

    loading_waiter =
      Task.async(fn ->
        claim(admission, loading_source, [loading_module], "owner-after-load")
      end)

    pending_waiter =
      Task.async(fn -> claim(admission, pending_source, [pending_module], "pending") end)

    assert await_waiter_count(admission, loading_source, 1, 1_000)
    assert await_waiter_count(admission, pending_source, 1, 1_000)

    loading_owner_monitor = Process.monitor(loading_owner)
    Process.exit(loading_owner, :kill)

    assert_receive {:DOWN, ^loading_owner_monitor, :process, ^loading_owner, :killed},
                   @event_timeout

    assert {:ok, {:error, {:generation_failed, ^loading_source}}} =
             Task.yield(loading_waiter, 1_000)

    assert {:ok, {:error, {:generation_failed, ^pending_source}}} =
             Task.yield(pending_waiter, 1_000)

    Enum.each(
      [committed_claim, shared_committed_claim, loading_claim, pending_claim],
      fn stale_claim ->
        source = stale_claim.source

        assert {:error, {:generation_failed, ^source}} =
                 ArtifactAdmission.mark_loading(stale_claim, server: admission)

        assert {:error, {:generation_failed, ^source}} =
                 ArtifactAdmission.commit_attempt(stale_claim, server: admission)

        assert {:error, {:generation_failed, ^source}} =
                 ArtifactAdmission.abort_attempt(stale_claim, server: admission)
      end
    )

    assert {:ok, [^committed_module]} =
             ArtifactAdmission.source_modules(committed_source, server: admission)

    assert {:ok, [^loading_module]} =
             ArtifactAdmission.source_modules(loading_source, server: admission)

    assert {:ok, [^pending_module]} =
             ArtifactAdmission.source_modules(pending_source, server: admission)

    state = :sys.get_state(admission)
    assert state.failed?
    assert state.module_sources[committed_module] == committed_source
    assert state.module_sources[loading_module] == loading_source
    assert state.module_sources[pending_module] == pending_source

    refute Enum.any?(state.sources, fn {_source, record} ->
             match?({:pending, _}, record.status)
           end)

    other_source = {:extension, unique_name(:after_failed_generation)}

    assert {:error, {:generation_failed, ^other_source}} =
             claim(admission, other_source, [unique_module("NeverReopened")], "never-reopened")

    pending_owner_monitor = Process.monitor(pending_owner)
    send(pending_owner, :stop)

    assert_receive {:DOWN, ^pending_owner_monitor, :process, ^pending_owner, :normal},
                   @event_timeout
  end

  test "admission restart rehydrates a fresh generation" do
    {admission, name} = start_restartable_admission(:fresh_restart)

    restarted = restart_admission(admission, name)
    source = {:extension, unique_name(:fresh_after_restart)}
    module = unique_module("FreshAfterRestart")

    assert {:ok, claim} = claim(restarted, source, [module], "fresh-after-restart")
    assert claim.acquired?
    assert :ok = ArtifactAdmission.abort_attempt(claim, server: restarted)
  end

  test "admission restart rehydrates generation sealing" do
    {admission, name} = start_restartable_admission(:sealed_restart)
    assert :ok = ArtifactAdmission.seal(server: admission)

    restarted = restart_admission(admission, name)
    source = {:extension, unique_name(:sealed_after_restart)}

    assert {:error, {:generation_sealed, ^source}} =
             claim(restarted, source, [unique_module("SealedAfterRestart")], "sealed-restart")
  end

  test "admission restart rehydrates committed source and module provenance" do
    {admission, name} = start_restartable_admission(:committed_restart)
    source = {:extension, unique_name(:restart_source)}
    module = unique_module("Restarted")
    fingerprint = :crypto.hash(:sha256, "restart")

    assert {:ok, claim} =
             ArtifactAdmission.claim_source_modules(source, [module], fingerprint,
               server: admission,
               source_fingerprint: fingerprint
             )

    assert :ok = ArtifactAdmission.commit_attempt(claim, server: admission)

    restarted = restart_admission(admission, name)
    assert {:ok, [^module]} = ArtifactAdmission.source_modules(source, server: restarted)
    assert {:ok, ^fingerprint} = ArtifactAdmission.source_fingerprint(source, server: restarted)

    assert {:ok, shared} =
             ArtifactAdmission.claim_source_modules(source, [module], fingerprint,
               server: restarted,
               source_fingerprint: fingerprint
             )

    refute shared.acquired?
  end

  test "admission restart with a claimed attempt fails the generation without reviving callers" do
    {admission, name} = start_restartable_admission(:pending_restart)
    source = {:extension, unique_name(:pending_restart_source)}
    module = unique_module("PendingRestart")
    assert {:ok, stale_claim} = claim(admission, source, [module], "pending-restart")
    parent = self()

    waiter =
      spawn(fn ->
        send(parent, {:old_pending_result, claim(admission, source, [module], "pending-restart")})
      end)

    waiter_ref = Process.monitor(waiter)
    assert await_waiter_count(admission, source, 1, 1_000)
    restarted = restart_admission(admission, name)

    assert_receive {:old_pending_result, {:error, {:artifact_admission_unavailable, ^admission}}},
                   1_000

    assert {:error, {:generation_failed, ^source}} =
             ArtifactAdmission.commit_attempt(stale_claim, server: restarted)

    assert {:error, {:generation_failed, ^source}} =
             claim(restarted, source, [module], "pending-restart")

    assert {:ok, [^module]} = ArtifactAdmission.source_modules(source, server: restarted)
    assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, :normal}, 1_000

    state = :sys.get_state(restarted)
    assert state.failed?
    assert state.module_sources[module] == source
    assert state.sources[source].status == :failed
  end

  test "admission restart with a loading attempt preserves provenance and failed status" do
    {admission, name} = start_restartable_admission(:loading_restart)
    source = {:extension, unique_name(:loading_restart_source)}
    module = unique_module("LoadingRestart")
    assert {:ok, claim} = claim(admission, source, [module], "loading-restart")
    assert :ok = ArtifactAdmission.mark_loading(claim, server: admission)
    parent = self()

    _waiter =
      spawn(fn ->
        send(parent, {:old_loading_result, claim(admission, source, [module], "loading-restart")})
      end)

    assert await_waiter_count(admission, source, 1, 1_000)
    restarted = restart_admission(admission, name)

    assert_receive {:old_loading_result, {:error, {:artifact_admission_unavailable, ^admission}}},
                   1_000

    assert {:error, {:generation_failed, ^source}} =
             ArtifactAdmission.commit_attempt(claim, server: restarted)

    assert {:ok, [^module]} = ArtifactAdmission.source_modules(source, server: restarted)

    other_source = {:extension, unique_name(:after_loading_restart)}

    assert {:error, {:generation_failed, ^other_source}} =
             claim(restarted, other_source, [unique_module("NeverAdmitted")], "failed-restart")

    restarted_again = restart_admission(restarted, name)

    assert {:error, {:generation_failed, ^other_source}} =
             claim(
               restarted_again,
               other_source,
               [unique_module("StillNeverAdmitted")],
               "failed-restart"
             )

    assert {:ok, [^module]} = ArtifactAdmission.source_modules(source, server: restarted_again)
  end

  test "explicit generation keys isolate equivalent claims across async tests" do
    {_first_owner, first_owner_name, _first_key} = start_isolated_owner(:first_private)
    {_second_owner, second_owner_name, _second_key} = start_isolated_owner(:second_private)

    first =
      start_supervised!(
        {ArtifactAdmission, name: nil, state_owner: first_owner_name},
        id: unique_name(:first_admission)
      )

    second =
      start_supervised!(
        {ArtifactAdmission, name: nil, state_owner: second_owner_name},
        id: unique_name(:second_admission)
      )

    source = {:extension, unique_name(:isolated_source)}
    module = unique_module("IsolatedOwner")

    assert {:ok, first_claim} = claim(first, source, [module], "isolated")
    assert {:ok, second_claim} = claim(second, source, [module], "isolated")
    assert first_claim.acquired?
    assert second_claim.acquired?
    assert first_claim.attempt_token != second_claim.attempt_token
    assert :ok = ArtifactAdmission.abort_attempt(first_claim, server: first)
    assert :ok = ArtifactAdmission.abort_attempt(second_claim, server: second)
  end

  defp start_isolated_owner(prefix) do
    name = unique_name(prefix)
    persistence_key = {__MODULE__, prefix, make_ref()}

    owner =
      start_supervised!(
        {ArtifactGenerationState, name: name, persistence_key: persistence_key},
        id: unique_name(:generation_owner_child)
      )

    on_exit(fn ->
      assert :ok = ArtifactGenerationState.reset_for_test(persistence_key)
    end)

    {owner, name, persistence_key}
  end

  defp start_restartable_admission(prefix) do
    {_owner, owner_name, _persistence_key} = start_isolated_owner(prefix)
    name = unique_name(prefix)

    admission =
      start_supervised!(
        {ArtifactAdmission, name: name, state_owner: owner_name},
        id: unique_name(:restartable_admission_child)
      )

    {admission, name}
  end

  defp restart_admission(admission, name) do
    monitor = Process.monitor(admission)
    Process.exit(admission, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^admission, :killed}, 1_000
    await_registered_restart(name, admission, 1_000)
  end

  defp await_waiter_count(admission, source, expected, remaining) when remaining > 0 do
    state = :sys.get_state(admission)

    case get_in(state, [:sources, source, :status]) do
      {:pending, %{waiters: waiters}} ->
        continue_waiter_count(
          Enum.count_until(waiters, expected + 1) == expected,
          admission,
          source,
          expected,
          remaining
        )

      _other ->
        continue_waiter_count(false, admission, source, expected, remaining)
    end
  end

  defp await_waiter_count(_admission, _source, _expected, 0), do: false

  defp continue_waiter_count(true, _admission, _source, _expected, _remaining), do: true

  defp continue_waiter_count(false, admission, source, expected, remaining) do
    receive do
    after
      1 -> await_waiter_count(admission, source, expected, remaining - 1)
    end
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

  defp claim(server, source, modules, fingerprint) do
    ArtifactAdmission.claim_source_modules(
      source,
      modules,
      :crypto.hash(:sha256, fingerprint),
      server: server
    )
  end

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

  defp unique_module(suffix),
    do: Module.concat(["Admission#{suffix}#{System.unique_integer([:positive])}"])
end
