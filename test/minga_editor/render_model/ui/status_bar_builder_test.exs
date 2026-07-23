defmodule MingaEditor.RenderModel.UI.StatusBarBuilderTest do
  use ExUnit.Case, async: true

  alias Minga.Language.Devicon
  alias Minga.Frontend.Adapter.GUI.StatusBarEncoder
  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Agent, as: SemanticStatusAgent
  alias Minga.RenderModel.UI.StatusBar.Cursor
  alias Minga.RenderModel.UI.StatusBar.Data, as: SemanticStatusData
  alias Minga.RenderModel.UI.StatusBar.Diagnostics
  alias Minga.RenderModel.UI.StatusBar.File, as: StatusFile
  alias Minga.RenderModel.UI.StatusBar.Git
  alias Minga.RenderModel.UI.StatusBar.Indent
  alias Minga.RenderModel.UI.StatusBar.Language
  alias Minga.RenderModel.UI.StatusBar.Operation, as: StatusOperation
  alias Minga.RenderModel.UI.StatusBar.Selection
  alias Minga.RenderModel.UI.StatusBar.Workspace
  alias MingaEditor.RenderModel.UI.StatusBarBuilder
  alias MingaEditor.State.Operation
  alias MingaEditor.State.OperationProgress
  alias MingaEditor.State.OperationQueue
  alias MingaEditor.StatusBar.Data, as: EditorStatusData
  alias MingaEditor.StatusBar.Data.Agent, as: EditorStatusAgent
  alias MingaEditor.StatusBar.Data.Buffer, as: EditorStatusBuffer
  alias MingaEditor.StatusBar.Data.Common

  defp minimal_buffer_data do
    %EditorStatusData{common: minimal_common(), content: %EditorStatusBuffer{}}
  end

  defp minimal_agent_data do
    %EditorStatusData{
      common: minimal_common(),
      content: %EditorStatusAgent{
        model_name: "Codex",
        session_status: :thinking,
        message_count: 3
      }
    }
  end

  defp minimal_common do
    %Common{
      status: %SemanticStatusData{
        mode: :normal,
        safe_mode?: false,
        dirty?: false,
        cursor: %Cursor{line: 0, col: 0, line_count: 1},
        diagnostics: %Diagnostics{},
        language: %Language{lsp_status: :none, parser_status: :available},
        git: %Git{},
        file: %StatusFile{name: "test.ex", filetype: :elixir},
        recording: false,
        indent: %Indent{type: :spaces, size: 2},
        selection: %Selection{},
        agent: %SemanticStatusAgent{agent_status: :inactive},
        pending_keys: ""
      },
      raw_diagnostic_counts: {0, 0, 0, 0},
      mode_state: nil,
      buf_index: 1,
      buf_count: 1,
      notice: nil,
      selected_operation: nil,
      agent_status_command: nil,
      agent_theme_colors: nil,
      git_degraded: false,
      workspace: %Workspace{id: 0, kind: :manual, label: "Default", icon: ""},
      merge_conflict_count: 0
    }
  end

  defp put_common(%EditorStatusData{} = data, fun), do: %{data | common: fun.(data.common)}
  defp put_status(%Common{} = common, fun), do: %{common | status: fun.(common.status)}
  defp minimal_theme, do: MingaEditor.UI.Theme.get!(:doom_one)

  defp minimal_ctx do
    %{
      shell_state: %{tab_bar: nil},
      workspace: %MingaEditor.Session.State{
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

  defp expected_buffer_model(%EditorStatusData{common: %Common{status: status}}, workspace) do
    %StatusBar{content_kind: :buffer, data: semantic_expected_data(status), workspace: workspace}
  end

  defp expected_agent_model(
         %EditorStatusData{
           common: %Common{status: status},
           content: %EditorStatusAgent{} = content
         },
         workspace
       ) do
    data = %{
      semantic_expected_data(status)
      | agent: %{
          status.agent
          | model_name: content.model_name,
            session_status: content.session_status,
            message_count: content.message_count
        }
    }

    %StatusBar{content_kind: :agent, data: data, workspace: workspace}
  end

  defp semantic_expected_data(%SemanticStatusData{file: %StatusFile{} = file} = status) do
    {icon, icon_color} = Devicon.icon_and_color(file.filetype)
    %SemanticStatusData{status | file: %StatusFile{file | icon: icon, icon_color: icon_color}}
  end

  describe "build/3" do
    test "returns semantic StatusBar models for buffer and agent content" do
      buffer_model = StatusBarBuilder.build(minimal_buffer_data(), minimal_theme(), minimal_ctx())
      agent_model = StatusBarBuilder.build(minimal_agent_data(), minimal_theme(), minimal_ctx())

      assert %StatusBar{content_kind: :buffer, data: buffer_data} = buffer_model
      assert %StatusBar{content_kind: :agent, data: agent_data} = agent_model
      assert buffer_data.file.name == "test.ex"
      assert is_binary(buffer_data.file.icon)
      assert is_integer(buffer_data.file.icon_color)
      assert agent_data.agent.model_name == "Codex"
      assert agent_data.agent.session_status == :thinking
      assert agent_data.agent.message_count == 3
    end

    test "projects every selected operation field without interpreting punctuation" do
      operation =
        Operation.new(42, :git_commit, "repo", "Committing...", true, 42)
        |> Operation.queued("Committing...", OperationQueue.new!(2, 3))
        |> Operation.report_progress(OperationProgress.new!(4, 10))

      status_data = put_common(minimal_buffer_data(), &%{&1 | selected_operation: operation})
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

      status_data =
        put_common(minimal_buffer_data(), &%{&1 | selected_operation: without_ellipsis})

      without_ellipsis_model = StatusBarBuilder.build(status_data, minimal_theme(), minimal_ctx())

      assert without_ellipsis_model.operation.status == model.operation.status
      assert without_ellipsis_model.operation.kind == model.operation.kind
    end

    test "arbitrates macro, operation, notice, then diagnostic while retaining operation data" do
      operation = Operation.new(7, :lsp_rename, "main.ex", "Renaming", true, 7)

      data =
        put_common(minimal_buffer_data(), fn common ->
          common
          |> put_status(
            &%{
              &1
              | recording: {true, "q"},
                diagnostics: %{&1.diagnostics | hint: "diagnostic hint"}
            }
          )
          |> then(&%{&1 | selected_operation: operation, notice: "ordinary notice"})
        end)

      model = StatusBarBuilder.build(data, minimal_theme(), minimal_ctx())
      assert model.data.message == "recording @q"
      assert %StatusOperation{id: 7, message: "Renaming"} = model.operation

      operation_model =
        data
        |> put_common(&put_status(&1, fn status -> %{status | recording: false} end))
        |> StatusBarBuilder.build(minimal_theme(), minimal_ctx())

      assert operation_model.data.message == "Renaming"

      notice_model =
        data
        |> put_common(fn common ->
          common
          |> put_status(&%{&1 | recording: false})
          |> then(&%{&1 | selected_operation: nil})
        end)
        |> StatusBarBuilder.build(minimal_theme(), minimal_ctx())

      assert notice_model.data.message == "ordinary notice"

      terminal_operation = Operation.finish(operation, :success, "Renamed")

      terminal_dwell_model =
        data
        |> put_common(fn common ->
          common
          |> put_status(&%{&1 | recording: false})
          |> then(&%{&1 | selected_operation: terminal_operation})
        end)
        |> StatusBarBuilder.build(minimal_theme(), minimal_ctx())

      assert terminal_dwell_model.data.message == "ordinary notice"

      assert %StatusOperation{id: 7, status: :success, message: "Renamed"} =
               terminal_dwell_model.operation

      diagnostic_model =
        data
        |> put_common(fn common ->
          common
          |> put_status(&%{&1 | recording: false})
          |> then(&%{&1 | selected_operation: nil, notice: nil})
        end)
        |> StatusBarBuilder.build(minimal_theme(), minimal_ctx())

      assert diagnostic_model.data.message == "diagnostic hint"

      terminal_with_diagnostic =
        data
        |> put_common(fn common ->
          common
          |> put_status(&%{&1 | recording: false})
          |> then(&%{&1 | selected_operation: terminal_operation, notice: nil})
        end)
        |> StatusBarBuilder.build(minimal_theme(), minimal_ctx())

      assert terminal_with_diagnostic.data.message == "diagnostic hint"
      assert terminal_with_diagnostic.operation.status == :success
    end

    test "ordinary notice punctuation has no operation semantics" do
      for message <- ["Saved", "Saved…", "Saved..."] do
        model =
          minimal_buffer_data()
          |> put_common(&%{&1 | notice: message})
          |> StatusBarBuilder.build(minimal_theme(), minimal_ctx())

        assert model.data.message == message
        assert model.operation == nil
      end
    end

    test "includes active workspace summary when available" do
      model = StatusBarBuilder.build(minimal_buffer_data(), minimal_theme(), minimal_ctx())

      assert %Workspace{id: 0, kind: :manual} = model.workspace
    end

    test "encodes typed buffer and agent snapshots with byte parity" do
      theme = minimal_theme()
      ctx = minimal_ctx()
      buffer_snapshot = EditorStatusData.with_modeline_segments(minimal_buffer_data(), theme)
      agent_snapshot = EditorStatusData.with_modeline_segments(minimal_agent_data(), theme)
      buffer_model = StatusBarBuilder.build(minimal_buffer_data(), theme, ctx)
      agent_model = StatusBarBuilder.build(minimal_agent_data(), theme, ctx)

      buffer_cmd = StatusBarEncoder.encode_command(buffer_model)
      agent_cmd = StatusBarEncoder.encode_command(agent_model)
      expected_workspace = %Workspace{id: 0, kind: :manual, label: "Files", icon: "folder"}

      expected_buffer_cmd =
        StatusBarEncoder.encode_command(
          expected_buffer_model(buffer_snapshot, expected_workspace)
        )

      expected_agent_cmd =
        StatusBarEncoder.encode_command(expected_agent_model(agent_snapshot, expected_workspace))

      assert buffer_cmd == expected_buffer_cmd
      assert agent_cmd == expected_agent_cmd
      assert <<0x76, _section_count, 0x01, 0, 3, 1, _::binary>> = agent_cmd

      assert <<0x09, 17::16, 5, "Codex", 3::32, 1, 0, 0::16, 0::16, 0>> =
               :binary.part(agent_cmd, byte_size(agent_cmd) - 20, 20)
    end
  end
end
