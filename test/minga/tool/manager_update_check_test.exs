defmodule Minga.Tool.ManagerUpdateCheckTest do
  @moduledoc """
  Lifecycle tests for Tool Manager update checks.

  Each test starts a private Manager with its own ETS table, tools directory, and event registry, and uses recipes with unique names whose lookups are scripted per recipe. Lookups block on explicit gates, so no assertion depends on wall-clock timing.
  """
  use ExUnit.Case, async: true

  alias Minga.Events
  alias Minga.Tool.Installation
  alias Minga.Tool.Installer.Stub
  alias Minga.Tool.Manager
  alias Minga.Tool.Recipe
  alias Minga.Tool.Recipe.Registry, as: RecipeRegistry

  @moduletag :tmp_dir

  @topics [
    :tool_install_complete,
    :tool_update_check_started,
    :tool_update_check_complete,
    :tool_update_check_cancelled
  ]

  setup %{tmp_dir: tmp_dir} do
    unique = System.unique_integer([:positive])
    events = :"tool_update_events_#{unique}"
    start_supervised!({Events, name: events})
    for topic <- @topics, do: Events.subscribe(topic, registry: events)

    source = {:extension, :"tool_update_test_#{unique}"}
    on_exit(fn -> RecipeRegistry.unregister_source(source) end)

    %{
      unique: unique,
      events: events,
      source: source,
      tools_dir: tmp_dir,
      server: :"tool_manager_#{unique}",
      table: :"tool_manager_table_#{unique}"
    }
  end

  describe "check_updates/1" do
    test "replies before any lookup finishes and status, install, and uninstall stay responsive",
         ctx do
      [a, b] = start_manager(ctx, [{"a", "1.0.0", :gate}, {"b", "1.0.0", :gate}])
      extra = register_recipe(ctx, "extra")

      assert :ok = Manager.check_updates(ctx.server)
      worker_a = await_blocked(a)
      worker_b = await_blocked(b)

      assert Manager.update_check_active?(ctx.server)
      assert [_ | _] = Manager.tool_status_list(ctx.server)
      assert Manager.installed?(a, ctx.table)

      assert :ok = Manager.install(extra, ctx.server)
      assert_receive {:minga_event, :tool_install_complete, %{name: ^extra}}, 5_000
      assert :ok = Manager.uninstall(extra, ctx.server)

      Stub.release_scripted(worker_a, {:ok, "2.0.0"})
      Stub.release_scripted(worker_b, {:ok, "1.0.0"})

      assert %{updates: [{^a, "1.0.0", "2.0.0"}], errors: []} = await_complete(1)
      refute Manager.update_check_active?(ctx.server)
    end

    test "an empty installation completes at once", ctx do
      start_manager(ctx, [])

      assert :ok = Manager.check_updates(ctx.server)
      assert_receive {:minga_event, :tool_update_check_started, %{generation: 1, count: 0}}
      assert %{updates: [], errors: []} = await_complete(1)
    end
  end

  describe "concurrency" do
    test "at most four lookups run at once and queued lookups start as others finish", ctx do
      names = start_manager(ctx, for(i <- 1..6, do: {"t#{i}", "1.0.0", :gate}))

      :ok = Manager.check_updates(ctx.server)
      first = for _ <- 1..4, do: await_any_blocked(names)
      refute_receive {:latest_version_blocked, _, _}, 100

      [{_, w1} | rest] = first
      Stub.release_scripted(w1, {:ok, "1.0.0"})
      fifth = await_any_blocked(names)
      refute_receive {:latest_version_blocked, _, _}, 100

      for {_name, worker} <- [fifth | rest], do: Stub.release_scripted(worker, {:ok, "1.0.0"})
      sixth = await_any_blocked(names)
      Stub.release_scripted(elem(sixth, 1), {:ok, "1.0.0"})

      started = Enum.map([sixth, fifth | first], &elem(&1, 0))
      assert Enum.sort(started) == Enum.sort(names)
      assert %{updates: [], errors: []} = await_complete(1)
    end
  end

  describe "failures" do
    test "a lookup that exceeds its timeout is killed and reported", ctx do
      [a] = start_manager(ctx, [{"a", "1.0.0", :gate}], update_check_timeout: 50)

      :ok = Manager.check_updates(ctx.server)
      worker = await_blocked(a)
      ref = Process.monitor(worker)

      assert %{errors: [{^a, "timeout"}], updates: []} = await_complete(1)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    end

    test "a crashed lookup is reported and the next check succeeds", ctx do
      [a] = start_manager(ctx, [{"a", "1.0.0", :crash}])

      :ok = Manager.check_updates(ctx.server)
      assert %{errors: [{^a, reason}], updates: []} = await_complete(1)
      assert reason =~ "simulated crash"

      Stub.script_latest_version(a, {:ok, "2.0.0"})
      :ok = Manager.check_updates(ctx.server)
      assert %{errors: [], updates: [{^a, "1.0.0", "2.0.0"}]} = await_complete(2)
    end

    test "a failed lookup is reported as an error", ctx do
      [a] = start_manager(ctx, [{"a", "1.0.0", {:error, "registry down"}}])

      :ok = Manager.check_updates(ctx.server)
      assert %{errors: [{^a, "registry down"}], updates: []} = await_complete(1)
    end
  end

  describe "cancellation" do
    test "cancel_update_check kills lookups and reports the cancelled generation", ctx do
      [a] = start_manager(ctx, [{"a", "1.0.0", :gate}])

      :ok = Manager.check_updates(ctx.server)
      ref = a |> await_blocked() |> Process.monitor()

      assert :ok = Manager.cancel_update_check(ctx.server)
      assert_receive {:DOWN, ^ref, :process, _, :killed}

      assert_receive {:minga_event, :tool_update_check_cancelled,
                      %{generation: 1, reason: :cancelled}}

      refute Manager.update_check_active?(ctx.server)

      Stub.script_latest_version(a, {:ok, "2.0.0"})
      :ok = Manager.check_updates(ctx.server)
      assert %{updates: [{^a, "1.0.0", "2.0.0"}]} = await_complete(2)
      refute_received {:minga_event, :tool_update_check_complete, %{generation: 1}}
    end

    test "a new check supersedes the in-flight check", ctx do
      [a] = start_manager(ctx, [{"a", "1.0.0", :gate}])

      :ok = Manager.check_updates(ctx.server)
      ref = a |> await_blocked() |> Process.monitor()

      :ok = Manager.check_updates(ctx.server)
      assert_receive {:DOWN, ^ref, :process, _, :killed}

      assert_receive {:minga_event, :tool_update_check_cancelled,
                      %{generation: 1, reason: :superseded}}

      Stub.release_scripted(await_blocked(a), {:ok, "3.0.0"})
      assert %{updates: [{^a, "1.0.0", "3.0.0"}]} = await_complete(2)
      refute_received {:minga_event, :tool_update_check_complete, %{generation: 1}}
    end

    test "the check is cancelled when the requesting caller exits", ctx do
      [a] = start_manager(ctx, [{"a", "1.0.0", :gate}])
      test_pid = self()

      caller =
        spawn(fn ->
          send(test_pid, {:requested, Manager.check_updates(ctx.server)})

          receive do
            :exit -> :ok
          end
        end)

      assert_receive {:requested, :ok}
      ref = a |> await_blocked() |> Process.monitor()
      send(caller, :exit)

      assert_receive {:DOWN, ^ref, :process, _, :killed}

      assert_receive {:minga_event, :tool_update_check_cancelled,
                      %{generation: 1, reason: :requester_down}}

      Stub.script_latest_version(a, {:ok, "2.0.0"})
      :ok = Manager.check_updates(ctx.server)
      assert %{updates: [{^a, "1.0.0", "2.0.0"}]} = await_complete(2)
    end

    test "stopping the Manager kills its lookups and a restarted Manager starts clean", ctx do
      names = start_manager(ctx, [{"a", "1.0.0", :gate}, {"b", "1.0.0", :gate}])
      manager = GenServer.whereis(ctx.server)

      :ok = Manager.check_updates(ctx.server)
      refs = for name <- names, do: name |> await_blocked() |> Process.monitor()

      Process.exit(manager, :kill)

      for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, _})

      await_restart(ctx.server, manager)
      refute Manager.update_check_active?(ctx.server)
      assert Manager.cached_updates(ctx.table) == []

      for name <- names, do: Stub.script_latest_version(name, {:ok, "2.0.0"})
      :ok = Manager.check_updates(ctx.server)
      assert %{updates: updates, errors: []} = await_complete(1)
      assert updates == Enum.sort(for name <- names, do: {name, "1.0.0", "2.0.0"})
    end
  end

  describe "result correlation" do
    test "an accepted update is cached until the installation changes", ctx do
      [a] = start_manager(ctx, [{"a", "1.0.0", {:ok, "2.0.0"}}])

      :ok = Manager.check_updates(ctx.server)
      await_complete(1)

      assert Manager.cached_updates(ctx.table) == [{a, "1.0.0", "2.0.0"}]
      assert Manager.available_update(a, ctx.table) == {"1.0.0", "2.0.0"}
      assert status_of(ctx, a) == {:update_available, "1.0.0"}

      assert :ok = Manager.uninstall(a, ctx.server)
      assert Manager.cached_updates(ctx.table) == []
      assert Manager.available_update(a, ctx.table) == nil
      assert status_of(ctx, a) == {:not_installed, nil}
    end

    test "a result for a tool uninstalled during the check is discarded", ctx do
      [a] = start_manager(ctx, [{"a", "1.0.0", :gate}])

      :ok = Manager.check_updates(ctx.server)
      worker = await_blocked(a)
      assert :ok = Manager.uninstall(a, ctx.server)
      Stub.release_scripted(worker, {:ok, "9.9.9"})

      assert %{updates: [], errors: []} = await_complete(1)
      assert Manager.cached_updates(ctx.table) == []
      assert status_of(ctx, a) == {:not_installed, nil}
    end

    test "a result for a tool reinstalled during the check is discarded", ctx do
      [a] = start_manager(ctx, [{"a", "1.0.0", :gate}])

      :ok = Manager.check_updates(ctx.server)
      worker = await_blocked(a)
      assert :ok = Manager.update(a, ctx.server)
      assert_receive {:minga_event, :tool_install_complete, %{name: ^a}}, 5_000
      Stub.release_scripted(worker, {:ok, "9.9.9"})

      assert %{updates: [], errors: []} = await_complete(1)
      assert Manager.available_update(a, ctx.table) == nil
      assert {:installed, _version} = status_of(ctx, a)
    end

    test "a result for a recipe registered again during the check is discarded", ctx do
      [a] = start_manager(ctx, [{"a", "1.0.0", :gate}])

      :ok = Manager.check_updates(ctx.server)
      worker = await_blocked(a)
      register_recipe(ctx, "a", "replacement-package")
      Stub.release_scripted(worker, {:ok, "9.9.9"})

      assert %{updates: [], errors: []} = await_complete(1)
      assert Manager.cached_updates(ctx.table) == []
      assert status_of(ctx, a) == {:installed, "1.0.0"}
    end

    test "a cached update becomes invisible when its recipe changes", ctx do
      [a] = start_manager(ctx, [{"a", "1.0.0", {:ok, "2.0.0"}}])

      :ok = Manager.check_updates(ctx.server)
      await_complete(1)
      assert Manager.available_update(a, ctx.table) == {"1.0.0", "2.0.0"}

      register_recipe(ctx, "a", "replacement-package")
      assert Manager.available_update(a, ctx.table) == nil
      assert status_of(ctx, a) == {:installed, "1.0.0"}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Registers recipes, writes their receipts, scripts their lookups, and starts a private Manager.
  defp start_manager(ctx, tools, opts \\ []) do
    names =
      for {suffix, version, script} <- tools do
        name = register_recipe(ctx, suffix)
        write_receipt(ctx, name, version)
        Stub.script_latest_version(name, script_for(script))
        on_exit(fn -> Stub.clear_latest_version_script(name) end)
        name
      end

    start_supervised!(
      {Manager,
       Keyword.merge(
         [
           name: ctx.server,
           table: ctx.table,
           tools_dir: ctx.tools_dir,
           events_registry: ctx.events,
           update_check_timeout: 60_000
         ],
         opts
       )}
    )

    names
  end

  defp script_for(:gate), do: {:gate, self()}
  defp script_for(script), do: script

  defp register_recipe(ctx, suffix, package \\ "test-package") do
    name = :"tool_#{ctx.unique}_#{suffix}"

    recipe = %Recipe{
      name: name,
      label: "Tool #{suffix}",
      description: "Update check test tool",
      provides: ["tool-#{ctx.unique}-#{suffix}"],
      method: :npm,
      package: package
    }

    :ok = RecipeRegistry.register(recipe, ctx.source)
    name
  end

  defp write_receipt(ctx, name, version) do
    dir = Path.join(ctx.tools_dir, Atom.to_string(name))
    File.mkdir_p!(dir)

    installation = %Installation{
      name: name,
      version: version,
      installed_at: ~U[2026-01-01 00:00:00Z],
      method: :npm,
      path: dir
    }

    File.write!(
      Path.join(dir, "receipt.json"),
      installation |> Installation.to_receipt() |> :json.format()
    )
  end

  defp await_blocked(name) do
    assert_receive {:latest_version_blocked, ^name, worker}, 5_000
    worker
  end

  defp await_any_blocked(names) do
    assert_receive {:latest_version_blocked, name, worker}, 5_000
    assert name in names
    {name, worker}
  end

  defp await_complete(generation) do
    assert_receive {:minga_event, :tool_update_check_complete,
                    %{generation: ^generation} = payload},
                   5_000

    payload
  end

  defp status_of(ctx, name) do
    row = ctx.server |> Manager.tool_status_list() |> Enum.find(&(&1.recipe.name == name))
    {row.status, row.installed_version}
  end

  # The test supervisor restarts the killed Manager; wait until the new process owns the name.
  defp await_restart(name, old_pid, attempts \\ 500) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when attempts > 0 ->
        receive do
        after
          5 -> await_restart(name, old_pid, attempts - 1)
        end

      _ ->
        flunk("Manager #{inspect(name)} did not restart")
    end
  end
end
