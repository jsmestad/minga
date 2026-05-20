defmodule MingaEditor.Workspace.ChromeState.WorkspaceSummary do
  @moduledoc """
  User-facing summary for one workspace in shared chrome.

  This is presentation data derived from editor state. It is not a source of truth for workspace membership or session lifecycle.
  """

  alias MingaEditor.State.Workspace

  @type kind :: :manual | :agent
  @type status :: Workspace.agent_status()

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          kind: kind(),
          label: String.t(),
          icon: String.t(),
          color: non_neg_integer(),
          status: status(),
          attention?: boolean(),
          tab_count: non_neg_integer(),
          draft_count: non_neg_integer(),
          conflict_count: non_neg_integer(),
          running_background_count: non_neg_integer(),
          closeable?: boolean()
        }

  @enforce_keys [
    :id,
    :kind,
    :label,
    :icon,
    :color,
    :status,
    :attention?,
    :tab_count,
    :draft_count,
    :conflict_count,
    :running_background_count,
    :closeable?
  ]
  defstruct @enforce_keys

  @doc "Builds a workspace summary."
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    kind = Keyword.fetch!(attrs, :kind)

    if kind not in [:manual, :agent] do
      raise ArgumentError,
            "WorkspaceSummary only supports manual or agent workspaces, got #{inspect(kind)}"
    end

    closeable? = Keyword.get(attrs, :closeable?, kind == :agent)

    if kind == :manual and closeable? do
      raise ArgumentError, "manual workspaces cannot be closeable"
    end

    %__MODULE__{
      id: Keyword.fetch!(attrs, :id),
      kind: kind,
      label: Keyword.fetch!(attrs, :label),
      icon: Keyword.fetch!(attrs, :icon),
      color: Keyword.get(attrs, :color, 0),
      status: Keyword.get(attrs, :status, :idle),
      attention?: Keyword.get(attrs, :attention?, false),
      tab_count: Keyword.get(attrs, :tab_count, 0),
      draft_count: Keyword.get(attrs, :draft_count, 0),
      conflict_count: Keyword.get(attrs, :conflict_count, 0),
      running_background_count: Keyword.get(attrs, :running_background_count, 0),
      closeable?: closeable?
    }
  end
end
