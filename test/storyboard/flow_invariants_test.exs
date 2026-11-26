defmodule Minga.Storyboard.FlowInvariantsTest do
  @moduledoc """
  The flow-graph invariants 1 to 8 from `docs/design/storyboard.md`.

  Each invariant runs twice: over the inventory graph in `docs/design/scenarios.toml` (the ExUnit port of `design/tools/storyboard/check.py`), and over the registry's built scenarios in the real editor. A scenario whose surface is pending is listed, never failed. `flow_explorer_test.exs` runs the same invariants over every key the explorer presses.
  """

  use ExUnit.Case, async: true

  import Minga.Test.Storyboard.Assertions

  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Explorer
  alias Minga.Test.Storyboard.Inventory
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Registry
  alias Minga.Test.Storyboard.Session

  @moduletag :storyboard

  @action_states ["needs_you", "waiting", "failed", "done"]

  setup_all do
    inventory = Inventory.load()
    %{inventory: inventory, problems: Inventory.flow_problems(inventory.scenarios)}
  end

  describe "the inventory graph (port of check.py)" do
    test "every exit points at a scenario that exists", %{problems: problems} do
      assert problems.unknown_target == []
    end

    test "1. every scenario is reachable from the cold start by keys", %{problems: problems} do
      assert problems.unreachable_by_key == []
    end

    test "1. every scenario is reachable from the cold start by clicks", %{
      inventory: inventory,
      problems: problems
    } do
      if inventory.phase == "final", do: assert(problems.unreachable_by_click == [])
    end

    test "2. every scenario reaches a resting view within three presses of esc or q", %{
      problems: problems
    } do
      assert problems.dead_end == []
    end

    test "3. every state that needs action offers one", %{inventory: inventory} do
      silent =
        for %{"states" => states} = scenario <- inventory.scenarios,
            scenario["status"] == "designed",
            scenario["outside_app"] != true,
            Enum.any?(states, &(&1 in @action_states)),
            not Enum.any?(Inventory.exits(scenario), &(not Inventory.back?(&1))),
            do: scenario["id"]

      assert silent == [], "states that need action but offer only a way back: #{inspect(silent)}"
    end

    test "4. every error names its next step", %{inventory: inventory} do
      silent =
        for %{"journey" => "errors"} = scenario <- inventory.scenarios,
            scenario["status"] == "designed",
            not Enum.any?(Inventory.exits(scenario), &(not Inventory.back?(&1))),
            do: scenario["id"]

      assert silent == [], "errors without a next step: #{inspect(silent)}"
    end

    test "5. every list has an empty state", %{problems: problems} do
      assert problems.no_empty_state == []
    end

    test "7. every exit of a transient surface has a key and a click", %{
      inventory: inventory,
      problems: problems
    } do
      assert problems.parity == []
      if inventory.phase == "final", do: assert(problems.no_click == [])
    end

    test "a state of other scenarios is not a place with exits of its own", %{problems: problems} do
      assert problems.state_with_exits == []
    end

    test "every designed scenario names board files that exist", %{problems: problems} do
      assert problems.missing_board == []
    end

    test "the port finds each kind of problem the Python checker finds" do
      scenarios = [
        %{
          "id" => "home",
          "status" => "designed",
          "cold_start" => true,
          "home" => true,
          "exits" => [
            %{"key" => "a", "click" => "A", "to" => "list"},
            %{"key" => "x", "to" => "ghost"}
          ]
        },
        %{
          "id" => "list",
          "status" => "designed",
          "list" => true,
          "transient" => true,
          "exits" => [
            %{"key" => "k", "click" => "", "to" => "trap"},
            %{"key" => "", "click" => "c", "to" => "home"}
          ]
        },
        %{
          "id" => "trap",
          "status" => "designed",
          "boards" => %{"macos" => "missing.dc.html"},
          "exits" => [%{"key" => "j", "click" => "", "to" => "list"}]
        },
        %{
          "id" => "island",
          "status" => "designed",
          "exits" => [%{"key" => "esc", "click" => "x", "to" => "home"}]
        },
        %{
          "id" => "narrow",
          "status" => "designed",
          "state_of" => true,
          "reached_by" => "any scenario at 80 columns",
          "exits" => [%{"key" => "esc", "click" => "x", "to" => "home"}]
        }
      ]

      problems = Inventory.flow_problems(scenarios, System.tmp_dir!())

      assert problems.unknown_target == ["home -> ghost"]
      assert problems.unreachable_by_key == ["island"]
      assert problems.unreachable_by_click == ["trap", "island"]
      assert problems.dead_end == ["list", "trap"]
      assert problems.no_empty_state == ["list (no empty_state)"]
      assert problems.no_click == ["list: 'k' has no click"]
      assert problems.parity == ["list: 'c' has no key"]
      assert problems.missing_board == ["trap: missing.dc.html"]
      assert problems.state_with_exits == ["narrow"]
    end
  end

  describe "the real editor" do
    test "1. every built scenario is reached by keys from the cold start" do
      for entry <- Registry.built() do
        model = entry |> Registry.drive() |> Session.model()

        assert Registry.classify(model) == entry.id,
               "#{entry.id} via #{inspect(entry.reach)}: #{Model.signature(model)}"
      end
    end

    test "1. every built scenario with a click path is reached by clicks; the rest are pending" do
      {pending, clickable} =
        Enum.split_with(Registry.built(), &match?({:pending, _}, &1.click_reach))

      for entry <- clickable do
        session =
          Enum.reduce(entry.click_reach, Session.start(entry.start), &Session.click(&2, &1))

        model = Session.model(session)

        assert Registry.classify(model) == entry.id,
               "#{entry.id} by clicks: #{Model.signature(model)}"
      end

      for %Entry{click_reach: {:pending, issue}} <- pending, do: assert(issue > 0)
    end

    test "2. from every built scenario, three presses of esc or q return to plain editing in the same window" do
      for entry <- Registry.built() do
        session = Registry.drive(entry)

        assert Explorer.way_out(session, fn -> Registry.drive(entry) end) == :ok,
               "#{entry.id} has no way out"
      end
    end

    test "3. every built scenario that shows a state that needs action offers an action" do
      for entry <- Registry.built(), action_state?(entry.id) do
        model = entry |> Registry.drive() |> Session.model()

        # A composer with the keyboard offers the reply itself.
        assert model.which_key != nil or Model.open?(model, :picker) or
                 Model.open?(model, :minibuffer) or composer_ready?(model) or
                 drawer_offers_action?(model),
               "#{entry.id} shows a state that needs action without offering one: #{Model.signature(model)}"
      end
    end

    test "4. every error notice in a built scenario names its next step" do
      for entry <- Registry.built() do
        entry |> Registry.drive() |> Session.model() |> assert_errors_name_next_step()
      end
    end

    test "5. every built list scenario has a registry entry for its empty state" do
      for entry <- Registry.built(),
          empty = Inventory.fetch!(entry.id)["empty_state"],
          empty != nil do
        assert {:ok, _} = Registry.fetch(empty)
      end
    end

    test "6. every which-key prefix has at least one child" do
      empty = for {:prefix, path, 0} <- trie_nodes(Defaults.leader_trie(), ["SPC"]), do: path
      assert empty == [], "which-key prefixes without children: #{inspect(empty)}"
    end

    test "6. every leader binding runs a registered command" do
      unregistered =
        for {:command, keys, command} <- trie_nodes(Defaults.leader_trie(), ["SPC"]),
            is_atom(command),
            Minga.Command.Registry.lookup(Minga.Command.Registry, command) == :error,
            do: {keys, command}

      assert unregistered == [],
             "leader keys bound to commands that do not exist: #{inspect(unregistered)}"
    end

    test "8. an interruption during which-key steals nothing: which-key, focus and mode survive" do
      for entry <- Registry.built(), entry.explore == :which_key do
        session = Registry.drive(entry)
        before = Session.model(session)
        after_interrupt = session |> Session.interrupt("background job failed") |> Session.model()

        assert after_interrupt.which_key == before.which_key, "#{entry.id}: which-key changed"
        assert after_interrupt.focus == before.focus, "#{entry.id}: focus moved"
        assert after_interrupt.mode == before.mode, "#{entry.id}: mode changed"
        assert Registry.classify(after_interrupt) == entry.id
      end
    end

    test "8. an interruption while editing leaves you editing in the same window" do
      session = Registry.drive(Registry.home())
      model = session |> Session.interrupt("background job failed") |> Session.model()

      assert Registry.classify(model) == Registry.home()
      assert_focus(model, :editor, window: session.home_window)
    end
  end

  @spec action_state?(String.t()) :: boolean()
  # The tasks drawer is an action surface: its focused rows carry their keys.
  defp drawer_offers_action?(%Model{
         ui: %{tasks_drawer: %{visible?: true, focused?: true, rows: rows}}
       }),
       do: Enum.any?(rows, &(&1.actions != []))

  defp drawer_offers_action?(%Model{}), do: false

  defp action_state?(id), do: Enum.any?(Inventory.fetch!(id)["states"], &(&1 in @action_states))

  # Walks the leader trie and lists every node: prefixes with their child count, and commands.
  @spec trie_nodes(Bindings.node_t(), [String.t()]) ::
          [{:prefix, String.t(), non_neg_integer()} | {:command, String.t(), term()}]
  defp trie_nodes(node, reversed_path) do
    children = Bindings.children(node)
    here = {:prefix, path_name(reversed_path), length(children)}
    [here | Enum.flat_map(children, &child_nodes(node, &1, reversed_path))]
  end

  @spec child_nodes(Bindings.node_t(), {Bindings.key(), term(), :command | :group}, [String.t()]) ::
          [tuple()]
  defp child_nodes(node, {key, _label, _kind}, reversed_path) do
    reversed_path = [Bindings.format_key(key) | reversed_path]

    case Bindings.lookup(node, key) do
      {:prefix, child} -> trie_nodes(child, reversed_path)
      {:command, command} -> [{:command, path_name(reversed_path), command}]
    end
  end

  @spec path_name([String.t()]) :: String.t()
  defp path_name(reversed_path), do: reversed_path |> Enum.reverse() |> Enum.join(" ")

  @spec composer_ready?(Model.t()) :: boolean()
  defp composer_ready?(%Model{focus: %{surface: :agent}, mode: :insert}), do: true
  defp composer_ready?(%Model{}), do: false
end
