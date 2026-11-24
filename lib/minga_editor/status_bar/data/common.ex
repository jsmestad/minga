defmodule MingaEditor.StatusBar.Data.Common do
  @moduledoc false

  # The fields after `plan_limit` feed the modeline segments (`MingaEditor.Shell.Traditional.Modeline`).

  alias Minga.RenderModel.UI.StatusBar.Data, as: StatusData
  alias Minga.RenderModel.UI.StatusBar.Diagnostics
  alias Minga.RenderModel.UI.StatusBar.Workspace
  alias MingaEditor.State.Operation
  alias MingaEditor.StatusBar.PlanLimit
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
          merge_conflict_count: non_neg_integer(),
          plan_limit: PlanLimit.t() | nil,
          needs_you_count: non_neg_integer(),
          minga_progress: {non_neg_integer(), pos_integer()} | nil,
          minga_file: String.t() | nil,
          minga_here?: boolean(),
          change_position: {pos_integer(), pos_integer()} | nil,
          failed_language_servers: [String.t()],
          config_problem: String.t() | nil,
          keymap_server: Minga.Keymap.server(),
          key_hints?: boolean()
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
  defstruct [
              plan_limit: nil,
              needs_you_count: 0,
              minga_progress: nil,
              minga_file: nil,
              minga_here?: false,
              change_position: nil,
              failed_language_servers: [],
              config_problem: nil,
              keymap_server: Minga.Keymap.default_server(),
              key_hints?: true
            ] ++ @enforce_keys
end
