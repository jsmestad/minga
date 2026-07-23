defmodule MingaEditor.StatusBar.Data.Common do
  @moduledoc false

  alias Minga.RenderModel.UI.StatusBar.Data, as: StatusData
  alias Minga.RenderModel.UI.StatusBar.Diagnostics
  alias Minga.RenderModel.UI.StatusBar.Workspace
  alias MingaEditor.State.Operation
  alias MingaEditor.UI.Theme

  @type t :: %__MODULE__{
          status: StatusData.t(),
          raw_diagnostic_counts: Diagnostics.counts() | nil,
          mode_state: Minga.Mode.state() | nil,
          buf_index: pos_integer(),
          buf_count: non_neg_integer(),
          notice: String.t() | nil,
          selected_operation: Operation.t() | nil,
          agent_status_command: String.t() | nil,
          agent_theme_colors: Theme.Agent.t() | nil,
          git_degraded: boolean(),
          workspace: Workspace.t() | nil,
          merge_conflict_count: non_neg_integer()
        }

  @enforce_keys [
    :status,
    :raw_diagnostic_counts,
    :mode_state,
    :buf_index,
    :buf_count,
    :notice,
    :selected_operation,
    :agent_status_command,
    :agent_theme_colors,
    :git_degraded,
    :workspace,
    :merge_conflict_count
  ]
  defstruct @enforce_keys
end
