defmodule Minga.Storyboard.JourneysTest do
  @moduledoc """
  The main journeys from `docs/design/storyboard.md` as scripted flows.

  Every step is checked against the inventory's exit table, so a journey cannot drift from the design. Each journey then runs in the real editor up to its first pending scenario; a step that lands on the wrong scenario fails. A journey that reaches a pending surface reports which ticket it waits on.
  """

  use ExUnit.Case, async: true

  alias Minga.Test.Storyboard.Journeys
  alias Minga.Test.Storyboard.Registry

  @moduletag :storyboard

  test "the main journeys from storyboard.md are all scripted" do
    names = Enum.map(Journeys.all(), & &1.name)

    for name <- [
          "approve a request",
          "review and keep a change",
          "recover from a rate limit",
          "a failing test, then Minga fixes it, then review",
          "open a file across a multi-file change"
        ] do
      assert name in names, "journey #{inspect(name)} is not scripted"
    end
  end

  test "the runner follows built scenarios end to end and keeps every frame" do
    journey = %{
      name: "leader and back, then a selection and back",
      start: "edit.plain",
      steps: [
        %{key: "SPC (pause)", to: "edit.whichkey.leader", press: nil},
        %{key: "esc", to: "edit.plain", press: nil},
        %{key: "v", to: "edit.visual", press: nil},
        %{key: "esc", to: "edit.plain", press: nil}
      ]
    }

    assert Journeys.validate(journey) == []
    assert {:ok, frames} = Journeys.run(journey)
    assert Enum.map(frames, & &1.scenario) == Journeys.scenario_ids(journey)
  end

  test "the runner fails a step that lands on the wrong scenario" do
    journey = %{
      name: "wrong turn",
      start: "edit.plain",
      steps: [%{key: "v", to: "edit.whichkey.leader", press: nil}]
    }

    assert {:error, message, [_start, _wrong]} = Journeys.run(journey)
    assert message =~ "expected edit.whichkey.leader"

    assert ["wrong turn: edit.plain has no exit \"v\" to edit.whichkey.leader"] =
             Journeys.validate(journey)
  end

  for journey <- Journeys.all() do
    @name journey.name

    test "#{journey.name}: every step is a designed exit" do
      journey = Enum.find(Journeys.all(), &(&1.name == @name))
      assert Journeys.validate(journey) == []

      for id <- Journeys.scenario_ids(journey) do
        assert {:ok, _entry} = Registry.fetch(id),
               "#{@name} visits #{id}, which has no registry entry"
      end
    end

    test "#{journey.name}: runs in the real editor up to its first pending surface" do
      journey = Enum.find(Journeys.all(), &(&1.name == @name))

      case Journeys.run(journey) do
        {:ok, frames} ->
          assert length(frames) == length(journey.steps) + 1

        {:pending, scenario, issue, frames} ->
          IO.puts(
            "Journey #{inspect(@name)}: #{length(frames)} frames, then waits on ##{issue} at #{scenario}"
          )

          assert issue > 0

        {:error, message, _frames} ->
          flunk(message)
      end
    end
  end
end
