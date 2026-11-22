defmodule MingaAgent.StagedDraftKeeper.Recovery do
  @moduledoc """
  Staged agent edits of one workspace, offered to an Editor that starts for the project.

  `source` says where the edits came from:

    * `:live` — the view outlived the Editor that owned it (an Editor restart). Its changeset and forks are still running.
    * `:disk` — the view was rebuilt from the drafts persisted by an earlier run (a full restart).

  `changes` holds the view's diff entries for the review state. `base_changed` lists the restored paths whose file on disk changed since the edit was staged; publishing merges them or reports a conflict. `lost` lists drafts that could not be restored and are gone. `retained` lists drafts that could not be restored now but stay on disk for the next start.
  """

  alias MingaAgent.ProjectView

  @typedoc "A draft that could not be restored, named by its path."
  @type failed_draft :: {String.t(), term()}

  @type t :: %__MODULE__{
          workspace_id: non_neg_integer(),
          source: :live | :disk,
          view: ProjectView.t() | nil,
          changes: [map()],
          base_changed: [String.t()],
          lost: [failed_draft()],
          retained: [failed_draft()]
        }

  @enforce_keys [:workspace_id, :source]
  defstruct [
    :workspace_id,
    :source,
    view: nil,
    changes: [],
    base_changed: [],
    lost: [],
    retained: []
  ]

  @doc "A view that survived its Editor, with its current diff."
  @spec live(non_neg_integer(), ProjectView.t(), [map()]) :: t()
  def live(workspace_id, %ProjectView{} = view, changes) when is_list(changes) do
    %__MODULE__{workspace_id: workspace_id, source: :live, view: view, changes: changes}
  end

  @doc "The outcome of rebuilding one workspace's persisted drafts."
  @spec restored(non_neg_integer(), ProjectView.t() | nil, keyword()) :: t()
  def restored(workspace_id, view, fields) do
    %__MODULE__{
      workspace_id: workspace_id,
      source: :disk,
      view: view,
      changes: Keyword.get(fields, :changes, []),
      base_changed: Keyword.get(fields, :base_changed, []),
      lost: Keyword.get(fields, :lost, []),
      retained: Keyword.get(fields, :retained, [])
    }
  end
end
