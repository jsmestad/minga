defmodule Minga.RenderModel.UI.TasksDrawer.Row do
  @moduledoc """
  One row of the tasks drawer: a task, or a subagent beneath its task.

  `id` is the row's stable identity, so a click names the task it means rather than a position in a list that reorders as states change. `depth` is 0 for a task and 1 for a subagent; `last?` marks the last subagent of its task, so the tree draws `└─` instead of `├─`. `state` is a design-token state, or nil for a task that has not started work. `detail` holds the lines a needs-you row expands to show (the request), and `actions` the keys the row offers, in the order they are shown.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          depth: 0 | 1,
          last?: boolean(),
          state: Minga.Design.Tokens.state_id() | nil,
          title: String.t(),
          words: String.t(),
          age: String.t(),
          detail: [String.t()],
          actions: [Minga.RenderModel.UI.TasksDrawer.hint()],
          selected?: boolean()
        }

  @enforce_keys [:id, :title]
  defstruct [
    :id,
    :title,
    depth: 0,
    last?: false,
    state: nil,
    words: "",
    age: "",
    detail: [],
    actions: [],
    selected?: false
  ]
end
