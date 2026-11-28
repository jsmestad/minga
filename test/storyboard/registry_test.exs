defmodule Minga.Storyboard.RegistryTest do
  @moduledoc """
  Every designed scenario has a registry entry, every built entry drives the real editor into its scenario, and every built scenario matches its design checks.
  """

  use ExUnit.Case, async: true

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Inventory
  alias Minga.Test.Storyboard.Registry
  alias Minga.Test.Storyboard.Session

  @moduletag :storyboard

  describe "registry and inventory agree" do
    test "every designed scenario has a registry entry" do
      ids = MapSet.new(Registry.entries(), & &1.id)
      missing = Enum.reject(Inventory.designed_ids(), &MapSet.member?(ids, &1))

      assert missing == [],
             "designed scenarios without a registry entry (add a builder or Entry.pending/3): #{inspect(missing)}"
    end

    test "every registry entry names a scenario in the inventory, once" do
      ids = Enum.map(Registry.entries(), & &1.id)
      unknown = Enum.reject(ids, &match?({:ok, _}, Inventory.fetch(&1)))

      assert unknown == [],
             "registry entries with no scenario in scenarios.toml: #{inspect(unknown)}"

      assert ids -- Enum.uniq(ids) == [],
             "duplicate registry entries: #{inspect(ids -- Enum.uniq(ids))}"
    end

    test "every pending entry and pending check names an issue" do
      for entry <- Registry.entries(), issue <- Entry.waiting_on(entry) do
        assert is_integer(issue) and issue > 0, "#{entry.id} waits on #{inspect(issue)}"
      end
    end

    test "prints the pending list" do
      designed = MapSet.new(Inventory.designed_ids())
      entries = Enum.filter(Registry.entries(), &MapSet.member?(designed, &1.id))
      {implemented, rest} = Enum.split_with(entries, &Entry.implemented?/1)
      {partial, pending} = Enum.split_with(rest, &Entry.built?/1)

      IO.puts(pending_report(implemented, partial, pending))
      assert length(implemented) + length(partial) + length(pending) == MapSet.size(designed)
    end
  end

  describe "built scenarios" do
    for entry <- Registry.built() do
      @id entry.id

      @tag scenario: entry.id
      test "#{entry.id} is reached by its key path and classified back to itself" do
        entry = Registry.fetch!(@id)
        session = Registry.drive(entry)
        model = Session.model(session)

        assert Registry.classify(model) == entry.id,
               "#{entry.id} via #{inspect(entry.reach)} classified as #{inspect(Registry.classify(model))}: " <>
                 Minga.Test.Storyboard.Model.signature(model)
      end

      if entry.checks != [] do
        @tag scenario: entry.id
        test "#{entry.id} matches its design checks" do
          entry = Registry.fetch!(@id)
          model = entry |> Registry.drive() |> Session.model()

          failures =
            for %Check{pending: nil} = check <- entry.checks,
                {:error, message} <- [Check.run(check, model)],
                do: "#{check.name}: #{message}"

          assert failures == [],
                 "#{entry.id} differs from its design:\n" <> Enum.join(failures, "\n")

          promoted =
            for %Check{pending: issue} = check <- entry.checks,
                issue != nil,
                Check.run(check, model) == :ok,
                do: "#{check.name} (##{issue})"

          assert promoted == [],
                 "#{entry.id}: pending checks now pass; make them active with Check.new/2: #{inspect(promoted)}"
        end
      end
    end
  end

  @spec pending_report([Entry.t()], [Entry.t()], [Entry.t()]) :: String.t()
  defp pending_report(implemented, partial, pending) do
    by_issue =
      pending
      |> Enum.group_by(fn %Entry{status: {:pending, issue, _}} -> issue end, & &1.id)
      |> Enum.sort()
      |> Enum.map(fn {issue, ids} -> "  ##{issue}: #{Enum.join(ids, ", ")}" end)

    partial_lines =
      for entry <- partial do
        waits = entry |> Entry.waiting_on() |> Enum.map_join(", ", &"##{&1}")
        "  #{entry.id} (design checks pending #{waits})"
      end

    """

    Storyboard: #{length(implemented)} implemented, #{length(partial)} built with pending design checks, #{length(pending)} pending
    Implemented: #{Enum.map_join(implemented, ", ", & &1.id)}
    Built, checks pending:
    #{Enum.join(partial_lines, "\n")}
    Pending surfaces, by ticket:
    #{Enum.join(by_issue, "\n")}
    """
  end
end
