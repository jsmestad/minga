defmodule Minga.Storyboard.RenderTest do
  @moduledoc """
  The storyboard renders (#4036): every built scenario through the real render pipeline.

  The text-grid snapshots here are the existing snapshot system's view of each scenario at every terminal size (`docs/SNAPSHOT_TESTING.md`). A theme changes colours, never the grid, so each size has one snapshot and every theme must match it.

  The export test writes the packet transcripts the Go TUI and the macOS frontend replay. It runs only when `MINGA_STORYBOARD_OUT` names a directory (`scripts/storyboard render` sets it); see `docs/design/storyboard.md`, "Renders and baselines".
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Test.Storyboard.Inventory
  alias Minga.Test.Storyboard.Registry
  alias Minga.Test.Storyboard.Render
  alias Minga.Test.Storyboard.Session

  @moduletag :storyboard

  @designed Inventory.designed_ids()
  @built for entry <- Registry.built(), entry.id in @designed, do: entry.id

  for id <- @built, {cols, rows} <- Render.tui_sizes() do
    @id id
    @size "#{cols}x#{rows}"
    test "#{id} draws the same text grid in every theme at #{cols}x#{rows}" do
      [first | _] = themes = Render.themes()
      target = Enum.find(Render.targets(), &(&1.frontend == :tui and &1.size == @size))

      grids =
        for theme <- themes do
          session = Render.drive(@id, %{target | theme: theme})
          grid = Session.screen_text(session)

          assert Session.highlight_span_count(session) > 0,
                 "#{@id} renders without syntax highlighting; storyboard frames must show real tree-sitter colours"

          if theme == first do
            assert_screen_snapshot(session.ctx, "#{@id}_#{@size}")
          end

          Session.stop(session)
          {theme, grid}
        end

      {^first, reference} = hd(grids)

      for {theme, grid} <- tl(grids) do
        assert grid == reference,
               "#{@id} at #{@size} draws a different grid in #{theme} than in #{first}"
      end
    end
  end

  # One export test per scenario keeps each test short and lets them run side by side.
  for id <- @built do
    @id id
    @tag :storyboard_export
    test "exports the transcripts of #{id} when MINGA_STORYBOARD_OUT is set" do
      with dir when is_binary(dir) <- System.get_env("MINGA_STORYBOARD_OUT") do
        :ok = Render.export_scenario!(dir, Registry.fetch!(@id))
        assert length(File.ls!(Path.join([dir, "transcripts", @id]))) == length(Render.targets())
      end
    end
  end

  @tag :storyboard_export
  test "exports the journey strips and the manifest when MINGA_STORYBOARD_OUT is set" do
    with dir when is_binary(dir) <- System.get_env("MINGA_STORYBOARD_OUT") do
      :ok = Render.export_journeys!(dir)
      manifest = dir |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()
      assert length(manifest["scenarios"]) == length(@designed)
    end
  end
end
