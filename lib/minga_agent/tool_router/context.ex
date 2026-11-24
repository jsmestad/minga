defmodule MingaAgent.ToolRouter.Context do
  @moduledoc """
  Routing context captured by agent tool callbacks.

  `project_view` is the first routing layer. `fork_store` and `changeset` remain available during migration so existing no-ProjectView behavior can keep working unchanged.

  `edit_source` names who the routed edits belong to. A context bound to an admitted tool call carries Minga's author key; any other context carries the legacy unattributed `:agent` source.
  """

  alias Minga.Buffer.EditSource
  alias MingaAgent.ProjectView

  @typedoc "Fork store reference, nil when fork routing is disabled."
  @type fork_store :: pid() | nil

  @typedoc "Changeset reference, nil when changeset routing is disabled."
  @type changeset :: pid() | nil

  @type t :: %__MODULE__{
          project_view: ProjectView.t() | nil,
          fork_store: fork_store(),
          changeset: changeset(),
          edit_source: EditSource.undo_source()
        }

  defstruct project_view: nil, fork_store: nil, changeset: nil, edit_source: :agent

  @doc "Attributes the routed edits, including those through the ProjectView, to `source`."
  @spec attribute(t(), EditSource.undo_source()) :: t()
  def attribute(%__MODULE__{project_view: nil} = context, source),
    do: %{context | edit_source: source}

  def attribute(%__MODULE__{project_view: %ProjectView{} = view} = context, source),
    do: %{context | edit_source: source, project_view: ProjectView.attribute(view, source)}

  @doc "Clears the captured ProjectView so routing can fall back to forks or changesets."
  @spec clear_project_view(t()) :: t()
  def clear_project_view(%__MODULE__{} = context), do: %{context | project_view: nil}
end
