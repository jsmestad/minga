defmodule MingaEditor.RenderPipeline.WorkspaceIntent do
  @moduledoc """
  Explicit allowlisted workspace portion of an Editor-to-Renderer intent.

  The retained Agent transcript never crosses the boundary inside `agent_ui`. `agent_ui` carries an index-free snapshot and `agent_transcript_lines` carries the bounded scroll fact. `agent_transcript` has three phases: the Editor's `{:source, projection}` reference, `nil` while packed in a `MingaEditor.Renderer.Submission`, and the renderer-local `MingaEditor.RenderModel.UI.AgentChatResident` root after admission.
  """

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.RenderModel.UI.AgentChatResident
  alias MingaEditor.Session.State, as: SessionState

  @fields [
    :buffers,
    :file_tree,
    :agent_ui,
    :editing,
    :document_highlights,
    :cmd_hover_link,
    :mouse,
    :search,
    :last_search_pattern,
    :keymap_scope,
    :launchpad,
    :agent_transcript,
    :agent_transcript_lines
  ]

  @enforce_keys @fields
  defstruct @fields ++ [subagent_peek: nil, peek_transcript: nil]

  @type t :: %__MODULE__{
          buffers: term(),
          file_tree: term(),
          agent_ui: term(),
          editing: term(),
          document_highlights: term(),
          cmd_hover_link: term(),
          mouse: term(),
          search: MingaEditor.State.Search.Projection.t(),
          last_search_pattern: String.t() | nil,
          keymap_scope: atom(),
          launchpad: term(),
          agent_transcript: agent_transcript(),
          agent_transcript_lines: non_neg_integer(),
          subagent_peek: Minga.RenderModel.UI.SubagentPeek.t() | nil,
          peek_transcript: agent_transcript()
        }

  @type agent_transcript ::
          {:source, TranscriptProjection.t()} | AgentChatResident.t() | nil

  @spec from_workspace(SessionState.t(), MingaEditor.State.Search.Projection.t()) :: t()
  def from_workspace(%SessionState{} = workspace, %MingaEditor.State.Search.Projection{} = search) do
    %__MODULE__{
      buffers: workspace.buffers,
      file_tree: SessionState.file_tree_state(workspace),
      agent_ui: UIState.render_snapshot(workspace.agent_ui),
      editing: workspace.editing,
      document_highlights: workspace.document_highlights,
      cmd_hover_link: workspace.hover_observation.link,
      mouse: workspace.mouse,
      search: search,
      last_search_pattern: workspace.search.last_pattern,
      keymap_scope: workspace.keymap_scope,
      launchpad: workspace.launchpad,
      agent_transcript: {:source, workspace.agent_ui.panel.transcript},
      agent_transcript_lines: TranscriptProjection.line_count(workspace.agent_ui.panel.transcript)
    }
  end

  @doc "Returns the Editor projection this intent was built from, or nil after packing."
  @spec transcript_source(t()) :: TranscriptProjection.t() | nil
  def transcript_source(%__MODULE__{agent_transcript: {:source, projection}}), do: projection
  def transcript_source(%__MODULE__{}), do: nil

  @doc "Attaches captured peek metadata and the child's independently indexed transcript."
  @spec with_subagent_peek(
          t(),
          {Minga.RenderModel.UI.SubagentPeek.t() | nil, TranscriptProjection.t() | nil}
        ) ::
          t()
  def with_subagent_peek(%__MODULE__{} = workspace, {model, projection}) do
    source = if projection, do: {:source, projection}
    %{workspace | subagent_peek: model, peek_transcript: source}
  end

  @doc "Returns the child projection before packing, without ever borrowing the parent one."
  @spec peek_source(t()) :: TranscriptProjection.t() | nil
  def peek_source(%__MODULE__{peek_transcript: {:source, projection}}), do: projection
  def peek_source(%__MODULE__{}), do: nil

  @doc "Updates the child transcript phase independently of the parent."
  @spec with_peek_transcript(t(), agent_transcript()) :: t()
  def with_peek_transcript(%__MODULE__{} = workspace, transcript),
    do: %{workspace | peek_transcript: transcript}

  @doc "Installs the transcript phase for packing or for the renderer-local resident root."
  @spec with_agent_transcript(t(), agent_transcript()) :: t()
  def with_agent_transcript(%__MODULE__{} = workspace, transcript),
    do: %{workspace | agent_transcript: transcript}

  @spec record_agent_scroll_metrics(t(), non_neg_integer(), pos_integer()) :: t()
  def record_agent_scroll_metrics(
        %__MODULE__{agent_ui: agent_ui} = workspace,
        total_lines,
        visible_height
      ) do
    struct!(workspace,
      agent_ui: UIState.record_scroll_metrics(agent_ui, total_lines, visible_height)
    )
  end
end
