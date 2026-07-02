defmodule MingaEditor.Session.ChromeState.TabSummary do
  @moduledoc """
  User-facing summary for one visible content tab in workspace chrome.

  Tab summaries preserve workspace identity separately from path labels so the same logical path can appear in multiple workspaces without becoming ambiguous in chrome.
  """

  alias MingaEditor.State.Tab

  @type draft_state :: :none | :draft | :draft_elsewhere | :conflict

  @type kind :: Tab.kind()

  @type t :: %__MODULE__{
          id: Tab.id(),
          workspace_id: non_neg_integer(),
          kind: kind(),
          label: String.t(),
          path: String.t() | nil,
          icon: String.t(),
          dirty?: boolean(),
          draft_state: draft_state(),
          attention?: boolean(),
          pinned?: boolean(),
          ephemeral?: boolean(),
          tint_color: non_neg_integer()
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
    :attention?,
    :pinned?,
    :tint_color
  ]
  defstruct @enforce_keys ++ [ephemeral?: false]

  @doc "Builds a tab summary."
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    kind = Keyword.fetch!(attrs, :kind)

    %__MODULE__{
      id: Keyword.fetch!(attrs, :id),
      workspace_id: Keyword.fetch!(attrs, :workspace_id),
      kind: kind,
      label: Keyword.fetch!(attrs, :label),
      path: Keyword.get(attrs, :path),
      icon: Keyword.fetch!(attrs, :icon),
      dirty?: Keyword.get(attrs, :dirty?, false),
      draft_state: Keyword.get(attrs, :draft_state, :none),
      attention?: Keyword.get(attrs, :attention?, false),
      pinned?: Keyword.get(attrs, :pinned?, false),
      ephemeral?: Keyword.get(attrs, :ephemeral?, false),
      tint_color: Keyword.get(attrs, :tint_color, 0)
    }
  end
end
