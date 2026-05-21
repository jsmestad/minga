defmodule MingaAgent.ToolRouter.Context do
  @moduledoc """
  Routing context captured by agent tool callbacks.

  `project_view` is the first routing layer. `fork_store` and `changeset` remain available during migration so existing no-ProjectView behavior can keep working unchanged.
  """

  alias MingaAgent.ProjectView

  @typedoc "Fork store reference, nil when fork routing is disabled."
  @type fork_store :: pid() | nil

  @typedoc "Changeset reference, nil when changeset routing is disabled."
  @type changeset :: pid() | nil

  @type t :: %__MODULE__{
          project_view: ProjectView.t() | nil,
          fork_store: fork_store(),
          changeset: changeset()
        }

  defstruct project_view: nil, fork_store: nil, changeset: nil

  @doc "Clears the captured ProjectView so routing can fall back to forks or changesets."
  @spec clear_project_view(t()) :: t()
  def clear_project_view(%__MODULE__{} = context), do: %{context | project_view: nil}
end
