defmodule Minga.Storyboard.RenderGeometryTest do
  @moduledoc """
  The grid each render target lays out in follows the chrome open at the scenario's reached frame (`Render.fitted_target/2`), the way a frontend reports its row fit (ADR-0001). A scenario that shows chrome a frontend draws natively around the editor must have that grid in `test/storyboard/macos_geometry.json`.
  """

  use ExUnit.Case, async: true

  alias Minga.Test.Storyboard.Inventory
  alias Minga.Test.Storyboard.Model
  alias Minga.Test.Storyboard.Registry
  alias Minga.Test.Storyboard.Render
  alias Minga.Test.Storyboard.Session

  @moduletag :storyboard

  @designed Inventory.designed_ids()
  @built for entry <- Registry.built(), entry.id in @designed, do: entry.id

  defp target(frontend, size),
    do: Enum.find(Render.targets(), &(&1.frontend == frontend and &1.size == size))

  test "the chrome open at the reached frame picks the grid each frontend reports" do
    mac = target(:macos, "1440")
    tui = target(:tui, "120x40")

    cases = [
      {mac, [], {177, 43}},
      {mac, [:file_tree], {145, 43}},
      {mac, [:git_status], {145, 43}},
      {target(:macos, "1280"), [:file_tree], {125, 38}},
      {tui, [:file_tree], {tui.cols, tui.grid_rows}},
      {tui, [:git_status], {tui.cols, tui.grid_rows}}
    ]

    for {target, surfaces, {cols, rows}} <- cases do
      fitted = Render.fitted_target(target, %Model{ui: nil, surfaces: surfaces})

      assert {fitted.cols, fitted.grid_rows} == {cols, rows},
             "#{target.size} with #{inspect(surfaces)}"

      assert fitted.rows == if(target.frontend == :macos, do: rows, else: target.rows)
    end
  end

  test "chrome a frontend draws natively around the editor without an entry names the key to add" do
    mac = %{target(:macos, "1440") | chrome_grid: %{}}

    assert_raise ArgumentError, ~r/no "file_tree" entry/, fn ->
      Render.fitted_target(mac, %Model{ui: nil, surfaces: [:file_tree]})
    end
  end

  for id <- @built do
    @id id
    test "#{id} has a grid on every render target" do
      session = Registry.drive(@id)
      model = Session.model(session)
      Session.stop(session)

      for target <- Render.targets(), do: Render.fitted_target(target, model)
    end
  end
end
