defmodule MingaEditor.GenerationSupervisor do
  @moduledoc """
  Couples one Editor authority to its effect scheduler and worker supervisor.

  The `:one_for_all` generation boundary starts the task supervisor and
  scheduler before the Editor. If any member fails, all three are torn down
  before a replacement Editor can acquire authority, so an old worker cannot
  mutate resources after an Editor restart.
  """

  use Supervisor

  @typedoc "Options for the generation-owned process names and Editor child."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:task_supervisor_name, GenServer.name()}
          | {:scheduler_name, GenServer.name()}
          | {:max_admitted, pos_integer()}
          | {:editor, {module(), keyword()}}
          | {:observer, pid()}

  @spec start_link([start_opt()]) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    task_name = Keyword.get(opts, :task_supervisor_name, MingaEditor.EffectTaskSupervisor)
    scheduler_name = Keyword.get(opts, :scheduler_name, MingaEditor.EffectScheduler)
    {editor_module, editor_opts} = Keyword.get(opts, :editor, {MingaEditor, []})

    scheduler_opts =
      [
        name: scheduler_name,
        task_supervisor: task_name,
        max_admitted: Keyword.get(opts, :max_admitted, 64)
      ]
      |> maybe_put_observer(opts)

    owner_opts = Keyword.put(editor_opts, :effect_scheduler, scheduler_name)

    children = [
      Supervisor.child_spec({Task.Supervisor, name: task_name}, id: :effect_task_supervisor),
      Supervisor.child_spec({MingaEditor.EffectScheduler, scheduler_opts}, id: :effect_scheduler),
      Supervisor.child_spec({editor_module, owner_opts}, id: :editor_owner)
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @spec maybe_put_observer(keyword(), keyword()) :: keyword()
  defp maybe_put_observer(scheduler_opts, opts) do
    case Keyword.fetch(opts, :observer) do
      {:ok, observer} -> Keyword.put(scheduler_opts, :observer, observer)
      :error -> scheduler_opts
    end
  end
end
