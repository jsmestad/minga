defmodule MingaEditor.RenderModel.UI.StatusBarBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Operation, as: StatusOperation
  alias Minga.RenderModel.UI.StatusBar.Workspace
  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationProgress
  alias MingaEditor.State.OperationQueue
  alias MingaEditor.RenderModel.UI.StatusBarBuilder

  defp minimal_buffer_data do
    {:buffer,
     %{
       mode: :normal,
       mode_state: nil,
       safe_mode: false,
       cursor_line: 0,
       cursor_col: 0,
       line_count: 1,
       file_name: "test.ex",
       filetype: :elixir,
       dirty: false,
       git_branch: nil,
       git_diff_summary: nil,
       diagnostic_counts: nil,
       diagnostic_hint: nil,
       indent_type: :spaces,
       indent_size: 2,
       selection_info: nil,
       lsp_status: :none,
       parser_status: :available,
       buf_index: 1,
       buf_count: 1,
       macro_recording: false,
       agent_status: :inactive,
       active_tool_name: nil,
       agent_theme_colors: nil,
       background_subagent_count: 0,
       active_background_subagent_label: nil,
       notice: nil,
       workspace_label: "Default",
       workspace_draft_count: 0,
       workspace_conflict_count: 0,
       merge_conflict_count: 0
     }}
  end

  defp minimal_theme do
    MingaEditor.UI.Theme.get!(:doom_one)
  end

  defp minimal_ctx do
    %{
      shell_state: %{tab_bar: nil},
      workspace: %MingaEditor.Session.State{
        viewport: MingaEditor.Viewport.new(24, 80),
        editing: MingaEditor.VimState.new(),
        buffers: %MingaEditor.State.Buffers{active: nil, list: [], active_index: 0},
        windows: %MingaEditor.State.Windows{
          tree: MingaEditor.WindowTree.new(1),
          map: %{},
          active: 1,
          next_id: 2
        }
      }
    }
  end

  describe "build/3" do
    test "returns a semantic StatusBar model" do
      model = StatusBarBuilder.build(minimal_buffer_data(), minimal_theme(), minimal_ctx())

      assert %StatusBar{content_kind: :buffer, data: data} = model
      assert data.file.name == "test.ex"
      assert is_binary(data.file.icon)
      assert is_integer(data.file.icon_color)
    end

    test "projects every selected operation field without interpreting punctuation" do
      operation =
        Operation.new(42, :git_commit, "repo", "Committing...", true, 42)
        |> Operation.queued("Committing...", OperationQueue.new!(2, 3))
        |> Operation.report_progress(OperationProgress.new!(4, 10))

      {:buffer, data} = minimal_buffer_data()
      status_data = {:buffer, Map.put(data, :selected_operation, operation)}
      model = StatusBarBuilder.build(status_data, minimal_theme(), minimal_ctx())

      assert %StatusOperation{
               id: 42,
               kind: :git_commit,
               status: :queued,
               message: "Committing...",
               queue_position: 2,
               queue_total: 3,
               progress_current: 4,
               progress_total: 10,
               cancelable?: true
             } = model.operation

      without_ellipsis =
        Operation.new(42, :git_commit, "repo", "Committing", true, 42)
        |> Operation.queued("Committing", OperationQueue.new!(2, 3))
        |> Operation.report_progress(OperationProgress.new!(4, 10))

      status_data = {:buffer, Map.put(data, :selected_operation, without_ellipsis)}
      without_ellipsis_model = StatusBarBuilder.build(status_data, minimal_theme(), minimal_ctx())

      assert without_ellipsis_model.operation.status == model.operation.status
      assert without_ellipsis_model.operation.kind == model.operation.kind
    end

    test "arbitrates macro, operation, notice, then diagnostic while retaining operation data" do
      {:buffer, base} = minimal_buffer_data()
      operation = Operation.new(7, :lsp_rename, "main.ex", "Renaming", true, 7)

      data =
        Map.merge(base, %{
          macro_recording: {true, "q"},
          selected_operation: operation,
          notice: "ordinary notice",
          diagnostic_hint: "diagnostic hint"
        })

      model = StatusBarBuilder.build({:buffer, data}, minimal_theme(), minimal_ctx())
      assert model.data.message == "recording @q"
      assert %StatusOperation{id: 7, message: "Renaming"} = model.operation

      operation_model =
        StatusBarBuilder.build(
          {:buffer, %{data | macro_recording: false}},
          minimal_theme(),
          minimal_ctx()
        )

      assert operation_model.data.message == "Renaming"

      notice_model =
        StatusBarBuilder.build(
          {:buffer, %{data | macro_recording: false, selected_operation: nil}},
          minimal_theme(),
          minimal_ctx()
        )

      assert notice_model.data.message == "ordinary notice"

      terminal_operation = Operation.finish(operation, :success, "Renamed")

      terminal_dwell_model =
        StatusBarBuilder.build(
          {:buffer,
           %{
             data
             | macro_recording: false,
               selected_operation: terminal_operation
           }},
          minimal_theme(),
          minimal_ctx()
        )

      assert terminal_dwell_model.data.message == "ordinary notice"

      assert %StatusOperation{id: 7, status: :success, message: "Renamed"} =
               terminal_dwell_model.operation

      diagnostic_model =
        StatusBarBuilder.build(
          {:buffer, %{data | macro_recording: false, selected_operation: nil, notice: nil}},
          minimal_theme(),
          minimal_ctx()
        )

      assert diagnostic_model.data.message == "diagnostic hint"

      terminal_with_diagnostic =
        StatusBarBuilder.build(
          {:buffer,
           %{
             data
             | macro_recording: false,
               selected_operation: terminal_operation,
               notice: nil
           }},
          minimal_theme(),
          minimal_ctx()
        )

      assert terminal_with_diagnostic.data.message == "diagnostic hint"
      assert terminal_with_diagnostic.operation.status == :success
    end

    test "ordinary notice punctuation has no operation semantics" do
      {:buffer, data} = minimal_buffer_data()

      for message <- ["Saved", "Saved…", "Saved..."] do
        model =
          StatusBarBuilder.build(
            {:buffer, %{data | notice: message}},
            minimal_theme(),
            minimal_ctx()
          )

        assert model.data.message == message
        assert model.operation == nil
      end
    end

    test "includes active workspace summary when available" do
      model = StatusBarBuilder.build(minimal_buffer_data(), minimal_theme(), minimal_ctx())

      assert %Workspace{id: 0, kind: :manual} = model.workspace
    end
  end
end
