defmodule MingaEditor.Commands.DiagnosticsPickerTest do
  @moduledoc "Command-level diagnostics picker regressions."

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Command
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Sources.Diagnostics, as: DiagnosticsSource

  @commands [:diagnostic_list, :diagnostic_picker, :diagnostics_list]

  @tag :tmp_dir
  test "registered diagnostics picker commands use the current picker context", %{
    tmp_dir: tmp_dir
  } do
    {state, uri} = state_for_path(tmp_dir)

    Diagnostics.publish(:expert, uri, [
      %Diagnostic{
        range: %{start_line: 1, start_col: 2, end_line: 1, end_col: 6},
        severity: :warning,
        message: "unused variable",
        source: "expert"
      }
    ])

    on_exit(fn -> Diagnostics.clear(:expert, uri) end)

    for command <- @commands do
      assert {:picker, %{picker_ui: picker_ui}} =
               execute_registered(command, state).shell_runtime.state.modal

      assert picker_ui.source == DiagnosticsSource

      assert picker_ui.picker.items == [
               %Item{id: {1, 2}, label: "W 2:3  unused variable (expert)"}
             ]
    end
  end

  @tag :tmp_dir
  test "registered diagnostics picker remains closed for an empty current diagnostics store", %{
    tmp_dir: tmp_dir
  } do
    {state, uri} = state_for_path(tmp_dir)
    Diagnostics.clear(:expert, uri)

    assert execute_registered(:diagnostic_list, state) == state
  end

  defp execute_registered(command, state) do
    assert {:ok, %Command{execute: execute}} = Command.lookup(command)
    execute.(state)
  end

  defp state_for_path(tmp_dir) do
    path = Path.join(tmp_dir, "current.ex")
    state = TestHelpers.base_state(content: "alpha\nabcdef\nomega")
    :ok = Buffer.save_as(state.workspace.buffers.active, path)
    {state, SyncServer.path_to_uri(path)}
  end
end
