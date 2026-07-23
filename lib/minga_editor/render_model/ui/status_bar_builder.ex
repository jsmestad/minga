defmodule MingaEditor.RenderModel.UI.StatusBarBuilder do
  @moduledoc false

  alias Minga.Language.Devicon
  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Agent, as: SemanticStatusAgent
  alias Minga.RenderModel.UI.StatusBar.Data, as: SemanticStatusData
  alias Minga.RenderModel.UI.StatusBar.File, as: StatusFile
  alias Minga.RenderModel.UI.StatusBar.Operation, as: StatusOperation
  alias Minga.RenderModel.UI.StatusBar.Workspace, as: StatusWorkspace
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.WorkspaceSummary
  alias MingaEditor.State.Operation, as: EditorOperation
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias MingaEditor.StatusBar.Data.Agent, as: EditorStatusAgent
  alias MingaEditor.StatusBar.Data.Buffer, as: EditorStatusBuffer
  alias MingaEditor.StatusBar.Data.Common, as: EditorStatusCommon

  @spec build(StatusBarData.t(), term(), term()) :: StatusBar.t()
  def build(status_bar_data, theme, ctx) do
    %StatusBarData{common: %EditorStatusCommon{} = common, content: content} =
      StatusBarData.with_modeline_segments(status_bar_data, theme)

    chrome_state = ChromeState.from_editor_state(ctx)

    %StatusBar{
      content_kind: content_kind(content),
      data: data_model(common, content),
      workspace: active_workspace_model(chrome_state),
      operation: operation_model(common.selected_operation)
    }
  end

  @spec content_kind(EditorStatusBuffer.t() | EditorStatusAgent.t()) :: StatusBar.content_kind()
  defp content_kind(%EditorStatusBuffer{}), do: :buffer
  defp content_kind(%EditorStatusAgent{}), do: :agent

  @spec data_model(EditorStatusCommon.t(), EditorStatusBuffer.t() | EditorStatusAgent.t()) ::
          SemanticStatusData.t()
  defp data_model(
         %EditorStatusCommon{
           status: %SemanticStatusData{file: %StatusFile{} = file} = status
         } = common,
         content
       ) do
    {icon, icon_color} = Devicon.icon_and_color(file.filetype)

    %{
      status
      | file: %StatusFile{file | icon: icon, icon_color: icon_color},
        message: projected_message(common),
        agent: agent_model(status.agent, content)
    }
  end

  @spec agent_model(SemanticStatusAgent.t(), EditorStatusBuffer.t() | EditorStatusAgent.t()) ::
          SemanticStatusAgent.t()
  defp agent_model(%SemanticStatusAgent{} = agent, %EditorStatusBuffer{}), do: agent

  defp agent_model(%SemanticStatusAgent{} = agent, %EditorStatusAgent{} = content) do
    %{
      agent
      | model_name: content.model_name,
        session_status: content.session_status,
        message_count: content.message_count
    }
  end

  @spec projected_message(EditorStatusCommon.t()) :: String.t() | nil
  defp projected_message(%EditorStatusCommon{
         status: %SemanticStatusData{recording: {true, register}}
       }),
       do: "recording @#{register}"

  defp projected_message(%EditorStatusCommon{
         selected_operation: %EditorOperation{status: status, message: message}
       })
       when status in [:pending, :queued, :running],
       do: message

  defp projected_message(%EditorStatusCommon{notice: message}) when is_binary(message),
    do: message

  defp projected_message(%EditorStatusCommon{status: %SemanticStatusData{} = status}),
    do: status.diagnostics.hint

  @spec operation_model(EditorOperation.t() | nil) :: StatusOperation.t() | nil
  defp operation_model(nil), do: nil

  defp operation_model(%EditorOperation{} = operation) do
    %StatusOperation{
      id: operation.id,
      kind: operation.kind,
      status: operation.status,
      message: operation.message,
      queue_position: nested_value(operation.queue, :position),
      queue_total: nested_value(operation.queue, :total),
      progress_current: nested_value(operation.progress, :current),
      progress_total: nested_value(operation.progress, :total),
      cancelable?: operation.cancelable?
    }
  end

  @spec nested_value(struct() | nil, atom()) :: term() | nil
  defp nested_value(nil, _field), do: nil
  defp nested_value(value, field), do: Map.fetch!(value, field)

  @spec active_workspace_model(ChromeState.t()) :: StatusWorkspace.t() | nil
  defp active_workspace_model(%ChromeState{} = chrome_state) do
    chrome_state.workspaces
    |> Enum.find(&(&1.id == chrome_state.active_workspace_id))
    |> workspace_model(chrome_state)
  end

  @spec workspace_model(WorkspaceSummary.t() | nil, ChromeState.t()) :: StatusWorkspace.t() | nil
  defp workspace_model(nil, _chrome_state), do: nil

  defp workspace_model(%WorkspaceSummary{} = workspace, %ChromeState{} = chrome_state) do
    %StatusWorkspace{
      id: workspace.id,
      kind: workspace.kind,
      label: workspace.label,
      icon: workspace.icon,
      status: workspace.status,
      attention_count: chrome_state.attention_count,
      draft_count: workspace.draft_count,
      conflict_count: workspace.conflict_count,
      running_background_count: workspace.running_background_count,
      closeable?: workspace.closeable?,
      attention?: workspace.attention?
    }
  end
end
