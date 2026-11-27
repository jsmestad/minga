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
      {tui, [:git_status], {tui.cols, tui.grid_rows}},
      # The project home draws no tab bar or breadcrumb, so both frontends report a larger grid there.
      {mac, [:empty_state], {179, 45}},
      {target(:macos, "1280"), [:empty_state], {159, 39}},
      {tui, [:empty_state], {tui.cols, tui.rows - 1}},
      {target(:tui, "80x24"), [:empty_state], {80, 23}},
      {mac, [:minibuffer], {177, 39}},
      {target(:macos, "1280"), [:minibuffer], {156, 34}},
      {mac, [:tasks_drawer], {177, 31}},
      {mac, [:tasks_drawer, :agent_activity], {177, 31}},
      {target(:macos, "1280"), [:tasks_drawer, :agent_activity], {156, 26}},
      {mac, [:tasks_drawer, :minibuffer], {177, 26}},
      {mac, [:task_review], {177, 45}},
      {target(:macos, "1280"), [:task_review], {156, 39}},
      {mac, [:agent_activity, :task_review], {177, 43}},
      {target(:macos, "1280"), [:agent_activity, :task_review], {156, 38}},
      {mac, [:minibuffer, :agent_activity, :task_review], {177, 39}},
      {target(:macos, "1280"), [:minibuffer, :agent_activity, :task_review], {156, 34}},
      {tui, [:tasks_drawer, :minibuffer], {tui.cols, tui.grid_rows}}
    ]

    for {target, surfaces, {cols, rows}} <- cases do
      fitted = Render.fitted_target(target, %Model{ui: nil, surfaces: surfaces})

      assert {fitted.cols, fitted.grid_rows} == {cols, rows},
             "#{target.size} with #{inspect(surfaces)}"

      assert fitted.rows == if(target.frontend == :macos, do: rows, else: target.rows)
    end
  end

  test "the conversation carries the composer's fit on macOS, and only there" do
    for {size, cols} <- [{"1280", 153}, {"1440", 173}],
        surfaces <- [[:agent_chat], [:agent_chat, :agent_activity]] do
      fitted = Render.fitted_target(target(:macos, size), %Model{ui: nil, surfaces: surfaces})

      assert fitted.prompt_fit == {cols, 8}, "#{size} with #{inspect(surfaces)}"

      assert Render.transcript("s", Map.put(fitted, :theme, :astrodark), [])["prompt"] == %{
               "cols" => cols,
               "rows" => 8
             }
    end

    tui = target(:tui, "120x40")
    assert Render.fitted_target(tui, %Model{ui: nil, surfaces: [:agent_chat]}).prompt_fit == nil

    mac = target(:macos, "1440")
    assert Render.fitted_target(mac, %Model{ui: nil, surfaces: [:file_tree]}).prompt_fit == nil
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
