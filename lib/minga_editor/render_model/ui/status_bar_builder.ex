defmodule MingaEditor.RenderModel.UI.StatusBarBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.StatusBar
  alias Minga.RenderModel.UI.StatusBar.Agent
  alias Minga.RenderModel.UI.StatusBar.Cursor
  alias Minga.RenderModel.UI.StatusBar.Data, as: StatusData
  alias Minga.RenderModel.UI.StatusBar.Diagnostics
  alias Minga.RenderModel.UI.StatusBar.File, as: StatusFile
  alias Minga.RenderModel.UI.StatusBar.Git
  alias Minga.RenderModel.UI.StatusBar.Indent
  alias Minga.RenderModel.UI.StatusBar.Language
  alias Minga.RenderModel.UI.StatusBar.Selection
  alias Minga.RenderModel.UI.StatusBar.Workspace, as: StatusWorkspace
  alias MingaEditor.Session.ChromeState
  alias MingaEditor.Session.ChromeState.WorkspaceSummary
  alias MingaEditor.StatusBar.Data, as: StatusBarData
  alias MingaEditor.UI.Devicon

  @spec build(StatusBarData.t(), term(), term()) :: StatusBar.t()
  def build(status_bar_data, theme, ctx) do
    {content_kind, data} = StatusBarData.with_modeline_segments(status_bar_data, theme)
    chrome_state = ChromeState.from_editor_state(ctx)

    %StatusBar{
      content_kind: content_kind,
      data: data_model(data),
      workspace: active_workspace_model(chrome_state)
    }
  end

  @spec data_model(map()) :: StatusData.t()
  defp data_model(data) do
    {icon, icon_color} = Devicon.icon_and_color(Map.get(data, :filetype, :text))

    %StatusData{
      mode: Map.get(data, :mode, :normal),
      safe_mode?: Map.get(data, :safe_mode, false),
      dirty?: Map.get(data, :dirty, false),
      cursor: %Cursor{
        line: Map.get(data, :cursor_line, 0),
        col: Map.get(data, :cursor_col, 0),
        line_count: Map.get(data, :line_count, 1)
      },
      diagnostics: %Diagnostics{
        counts: diagnostic_counts(Map.get(data, :diagnostic_counts)),
        hint: Map.get(data, :diagnostic_hint)
      },
      language: %Language{
        lsp_status: Map.get(data, :lsp_status, :none),
        parser_status: Map.get(data, :parser_status, :available)
      },
      git: %Git{
        branch: Map.get(data, :git_branch),
        diff_summary: Map.get(data, :git_diff_summary)
      },
      file: %StatusFile{
        name: Map.get(data, :file_name, ""),
        filetype: Map.get(data, :filetype, :text),
        icon: icon,
        icon_color: icon_color
      },
      message: Map.get(data, :status_msg),
      recording: Map.get(data, :macro_recording, false),
      indent: %Indent{
        type: Map.get(data, :indent_type, :spaces),
        size: Map.get(data, :indent_size, 2)
      },
      selection: selection_model(Map.get(data, :selection_info)),
      agent: %Agent{
        model_name: Map.get(data, :model_name, "Agent"),
        message_count: Map.get(data, :message_count, 0),
        session_status: Map.get(data, :session_status),
        agent_status: Map.get(data, :agent_status),
        background_count: Map.get(data, :background_subagent_count, 0),
        background_label: Map.get(data, :active_background_subagent_label),
        active_tool_name: Map.get(data, :active_tool_name)
      },
      modeline_segments: Map.get(data, :modeline_segments)
    }
  end

  @spec diagnostic_counts(term()) :: Diagnostics.counts()
  defp diagnostic_counts({errors, warnings, info, hints}), do: {errors, warnings, info, hints}
  defp diagnostic_counts(_counts), do: {0, 0, 0, 0}

  @spec selection_model(StatusBarData.selection_info()) :: Selection.t()
  defp selection_model({:chars, count}), do: %Selection{mode: :chars, size: count}
  defp selection_model({:lines, count}), do: %Selection{mode: :lines, size: count}
  defp selection_model(_selection_info), do: %Selection{}

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
