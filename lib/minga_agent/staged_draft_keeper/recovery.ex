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
          workspace_id: non_neg_integer() | nil,
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

  @doc """
  The outcome of rebuilding one view's persisted drafts.

  `workspace_id` is `nil` only when no stored draft named its workspace. Failure reasons are reduced with `safe_reason/1`, because they end up in `*Messages*` and the log.
  """
  @spec restored(non_neg_integer() | nil, ProjectView.t() | nil, keyword()) :: t()
  def restored(workspace_id, view, fields) do
    %__MODULE__{
      workspace_id: workspace_id,
      source: :disk,
      view: view,
      changes: Keyword.get(fields, :changes, []),
      base_changed: Keyword.get(fields, :base_changed, []),
      lost: safe_failures(Keyword.get(fields, :lost, [])),
      retained: safe_failures(Keyword.get(fields, :retained, []))
    }
  end

  @doc """
  Reduces a failure reason to atoms and integers.

  Reasons can embed call arguments or file bytes. Strings, maps, lists, and processes become `:redacted`, so a reported reason never carries draft content.
  """
  @spec safe_reason(term()) :: term()
  def safe_reason(reason) when is_atom(reason) or is_integer(reason), do: reason

  def safe_reason(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.map(&safe_reason/1) |> List.to_tuple()

  def safe_reason(_reason), do: :redacted

  @spec safe_failures([failed_draft()]) :: [failed_draft()]
  defp safe_failures(failures),
    do: Enum.map(failures, fn {path, reason} -> {path, safe_reason(reason)} end)
end
