defmodule MingaEditor.Workspace.ChromeState.TabSummary do
  @moduledoc """
  User-facing summary for one file tab in workspace chrome.

  Tab summaries preserve workspace identity separately from path labels so the same logical path can appear in multiple workspaces without becoming ambiguous in chrome.
  """

  alias MingaEditor.State.Tab

  @type draft_state :: :none | :draft | :draft_elsewhere | :conflict

  @type t :: %__MODULE__{
          id: Tab.id(),
          workspace_id: non_neg_integer(),
          kind: Tab.kind(),
          label: String.t(),
          path: String.t() | nil,
          icon: String.t(),
          dirty?: boolean(),
          draft_state: draft_state(),
          attention?: boolean()
        }

  @enforce_keys [
    :id,
    :workspace_id,
    :kind,
    :label,
    :path,
    :icon,
    :dirty?,
    :draft_state,
    :attention?
  ]
  defstruct @enforce_keys

  @doc "Builds a tab summary."
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    %__MODULE__{
      id: Keyword.fetch!(attrs, :id),
      workspace_id: Keyword.fetch!(attrs, :workspace_id),
      kind: Keyword.fetch!(attrs, :kind),
      label: Keyword.fetch!(attrs, :label),
      path: Keyword.get(attrs, :path),
      icon: Keyword.fetch!(attrs, :icon),
      dirty?: Keyword.get(attrs, :dirty?, false),
      draft_state: Keyword.get(attrs, :draft_state, :none),
      attention?: Keyword.get(attrs, :attention?, false)
    }
  end
end
