defmodule MingaEditor.Commands.DiagnosticsPickerTest do
  @moduledoc "Command-level diagnostics picker regressions."

  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Command
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.UI.Picker.Context
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
        range: %{start_line: 1, start_col: 1, end_line: 1, end_col: 2},
        encoding: :utf32,
        severity: :info,
        message: "code point"
      },
      %Diagnostic{
        range: %{start_line: 1, start_col: 2, end_line: 1, end_col: 3},
        encoding: :utf16,
        severity: :warning,
        message: "code units"
      },
      %Diagnostic{
        range: %{start_line: 1, start_col: 4, end_line: 1, end_col: 5},
        severity: :error,
        message: "bytes",
        source: "expert"
      },
      %Diagnostic{
        range: %{start_line: 5, start_col: 2, end_line: 5, end_col: 3},
        encoding: :utf16,
        severity: :hint,
        message: "no line text"
      },
      %Diagnostic{
        range: %{start_line: 5, start_col: 3, end_line: 5, end_col: 4},
        severity: :info,
        message: "raw byte column"
      }
    ])

    on_exit(fn -> Diagnostics.clear(:expert, uri) end)

    for command <- @commands do
      assert {:picker, %{picker_ui: picker_ui}} =
               execute_registered(command, state).shell_runtime.state.modal

      assert picker_ui.source == DiagnosticsSource

      assert picker_ui.picker.items == [
               %Item{id: {1, 4}, label: "I 2:5  code point"},
               %Item{id: {1, 4}, label: "W 2:5  code units"},
               %Item{id: {1, 4}, label: "E 2:5  bytes (expert)"},
               %Item{id: {5, 0}, label: "H 6:1  no line text"},
               %Item{id: {5, 3}, label: "I 6:4  raw byte column"}
             ]
    end
  end

  @tag :tmp_dir
  test "reads just the distinct lines that need encoding conversion", %{tmp_dir: tmp_dir} do
    {state, uri} = state_for_path(tmp_dir)
    buffer = state.workspace.buffers.active
    context = Context.from_editor_state(state)

    utf8 = picker_diagnostic(0, :utf8)
    Diagnostics.publish(:expert, uri, [utf8])
    on_exit(fn -> Diagnostics.clear(:expert, uri) end)

    :erlang.trace(buffer, true, [:receive, {:tracer, self()}])

    try do
      assert [%Item{id: {0, 0}}] = DiagnosticsSource.candidates(context)
      assert_line_reads(buffer, [])

      Diagnostics.publish(:expert, uri, [
        utf8,
        picker_diagnostic(1, :utf16),
        picker_diagnostic(1, :utf32),
        picker_diagnostic(2, :utf16)
      ])

      assert [%Item{}, %Item{}, %Item{}, %Item{}] = DiagnosticsSource.candidates(context)
      assert_line_reads(buffer, [[1, 2]])
    after
      :erlang.trace(buffer, false, [:receive])
    end
  end

  @tag :tmp_dir
  test "an empty diagnostics store opens a list that says so and points somewhere", %{
    tmp_dir: tmp_dir
  } do
    {state, uri} = state_for_path(tmp_dir)
    Diagnostics.clear(:expert, uri)

    opened = execute_registered(:diagnostic_list, state)
    {:picker, %{picker_ui: %{picker: picker}}} = opened.shell_runtime.state.modal

    assert %{title: "No problems in this file.", why: "No language server checks this file."} =
             picker.empty

    assert Enum.map(picker.filtered, &{&1.label, &1.annotation}) == [
             {"Install a language server", "SPC c l I"},
             {"Show what ran", "SPC c l i"}
           ]
  end

  defp picker_diagnostic(line, encoding) do
    %Diagnostic{
      range: %{start_line: line, start_col: 0, end_line: line, end_col: 1},
      severity: :info,
      message: Atom.to_string(encoding),
      encoding: encoding
    }
  end

  defp assert_line_reads(buffer, batches) do
    delivery_ref = :erlang.trace_delivered(buffer)
    assert_receive {:trace_delivered, ^buffer, ^delivery_ref}

    for expected <- batches do
      assert_received {:trace, ^buffer, :receive, {:"$gen_call", _, {:lines_at, actual}}}
      assert Enum.sort(actual) == expected
    end

    refute_received {:trace, ^buffer, :receive, {:"$gen_call", _, {:lines_at, _}}}
    refute_received {:trace, ^buffer, :receive, {:"$gen_call", _, {:lines, _, _}}}
  end

  defp execute_registered(command, state) do
    assert {:ok, %Command{execute: execute}} = Command.lookup(command)
    execute.(state)
  end

  defp state_for_path(tmp_dir) do
    path = Path.join(tmp_dir, "current.ex")
    state = TestHelpers.base_state(content: "alpha\n🙂abcdef\nomega")
    :ok = Buffer.save_as(state.workspace.buffers.active, path)
    {state, SyncServer.path_to_uri(path)}
  end
end
