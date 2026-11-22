defmodule MingaEditor.Extension.Sidebar.Entry do
  @moduledoc """
  Source-owned sidebar registration metadata.

  The sidebar registry stores this struct in ETS so layout, input, TUI rendering, and GUI emit share one typed shape instead of passing bare maps across module boundaries.
  """

  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.Extension.Sidebar.Snapshot

  @typedoc "Contribution source that owns a sidebar."
  @type source :: ContributionCleanup.contribution_source()

  @typedoc "Sidebar placement."
  @type placement :: :left

  @typedoc "Action handler invoked through the editor action pipeline."
  @type action_handler ::
          (MingaEditor.State.t(), String.t(), map() -> MingaEditor.State.t())
          | {module(), atom()}
          | {module(), atom(), [term()]}
          | nil

  @type t :: %__MODULE__{
          source: source(),
          id: String.t(),
          display_name: String.t(),
          description: String.t(),
          placement: placement(),
          priority: integer(),
          preferred_width: pos_integer(),
          visible?: boolean(),
          focused?: boolean(),
          semantic_kind: String.t(),
          icon: String.t(),
          input_handler: module() | nil,
          action_handler: action_handler(),
          badge_count: non_neg_integer() | nil,
          snapshot: Snapshot.t()
        }

  @enforce_keys [:source, :id, :display_name, :semantic_kind]
  defstruct source: nil,
            id: nil,
            display_name: nil,
            description: "",
            placement: :left,
            priority: 100,
            preferred_width: 30,
            visible?: false,
            focused?: false,
            semantic_kind: nil,
            icon: "sidebar.left",
            input_handler: nil,
            action_handler: nil,
            badge_count: nil,
            snapshot: Snapshot.new()

  @git_status_id "git_status"

  @doc "Returns the reserved Git Status sidebar identity."
  @spec git_status_id() :: String.t()
  def git_status_id, do: @git_status_id

  @doc "Creates the sidebar entry for the active Git Status provider."
  @spec git_status(source()) :: t()
  def git_status(source) do
    %__MODULE__{
      source: source,
      id: @git_status_id,
      display_name: "Git Status",
      description: "Repository changes",
      priority: 20,
      preferred_width: 30,
      semantic_kind: @git_status_id,
      input_handler: MingaEditor.Input.GitStatus,
      icon: "point.3.filled.connected.trianglepath.dotted",
      badge_count: 0
    }
  end

  @doc "Updates visibility, the changed-file count, and keyboard focus for Git Status."
  @spec present_git_status(t(), boolean(), non_neg_integer(), boolean()) :: t()
  def present_git_status(%__MODULE__{id: @git_status_id} = entry, visible?, badge_count, focused?) do
    %{entry | visible?: visible?, badge_count: badge_count, focused?: visible? and focused?}
  end

  @doc "Updates the cached snapshot."
  @spec publish_snapshot(t(), Snapshot.t()) :: t()
  def publish_snapshot(%__MODULE__{} = entry, %Snapshot{} = snapshot),
    do: %{entry | snapshot: snapshot}

  @doc "Updates visibility."
  @spec set_visible(t(), boolean()) :: t()
  def set_visible(%__MODULE__{} = entry, visible?) when is_boolean(visible?),
    do: %{entry | visible?: visible?}

  @doc "Updates focus."
  @spec set_focused(t(), boolean()) :: t()
  def set_focused(%__MODULE__{} = entry, focused?) when is_boolean(focused?),
    do: %{entry | focused?: focused?}
end
