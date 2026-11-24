defmodule Minga.Extensions.PackLoaderSupervisionTest do
  use ExUnit.Case, async: true

  alias Minga.Extensions.PackLoaderProbe

  @pairs [
    {Minga.Language.Registry, Minga.Extensions.LanguagePacks},
    {Minga.Config.ThemeRegistry, Minga.Extensions.ThemePacks},
    {Minga.Tool.Recipe.Registry, Minga.Extensions.RecipePacks}
  ]

  test "a pack loader runs again when the registry before it restarts" do
    registry = %{id: :registry, start: {Agent, :start_link, [fn -> :empty end]}}

    supervisor =
      start_supervised!(%{
        id: :pack_tree,
        start:
          {Supervisor, :start_link,
           [[registry, {PackLoaderProbe, notify: self()}], [strategy: :rest_for_one]]},
        type: :supervisor
      })

    assert_receive {:pack_loaded, _first}

    {:registry, registry_pid, _type, _modules} =
      List.keyfind(Supervisor.which_children(supervisor), :registry, 0)

    ref = Process.monitor(registry_pid)
    Process.exit(registry_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^registry_pid, :killed}

    assert_receive {:pack_loaded, _second}
  end

  test "every bundled pack loader is a restartable child placed after its registry" do
    ids =
      Minga.Foundation.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reverse()

    for {registry, loader} <- @pairs do
      assert {:ok, %{restart: :transient}} =
               :supervisor.get_childspec(Minga.Foundation.Supervisor, loader)

      assert Enum.find_index(ids, &(&1 == registry)) < Enum.find_index(ids, &(&1 == loader))
    end
  end
end
