defmodule MingaEditor.Commands.Tasks do
  @moduledoc """
  Commands for `*minga-tasks*`, the drawer that lists every task Minga is working on.

  `SPC a a` and a click on the modeline's needs-you segment run `:agent_tasks`; `SPC a n` runs `:agent_new_task`, the drawer's `c`. The drawer's own keys live in the `:tasks` keymap scope and run through `MingaEditor.Input.TasksDrawer`.
  """

  use MingaEditor.Commands.Provider

  alias MingaEditor.Shell.Traditional.TasksDrawerWorkflow

  command(:agent_tasks, "Tasks",
    requires_buffer: false,
    execute: &TasksDrawerWorkflow.toggle/1
  )

  command(:agent_new_task, "New task",
    requires_buffer: false,
    execute: &TasksDrawerWorkflow.new_task/1
  )
end
