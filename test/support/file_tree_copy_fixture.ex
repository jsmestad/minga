defmodule Minga.Test.FileTreeCopyFixture do
  @moduledoc "Synchronizes command-state tests with their private file-tree copy worker."

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.Copy
  alias MingaEditor.State, as: EditorState

  @doc "Starts a scheduler attached to the calling test as its owner."
  @spec start_scheduler() :: pid()
  def start_scheduler do
    task_supervisor = start_supervised!({Task.Supervisor, []})
    scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
    :ok = EffectScheduler.attach(scheduler, self())
    scheduler
  end

  @doc "Attaches the test's private scheduler to command-state fixtures."
  @spec install_scheduler(EditorState.t()) :: EditorState.t()
  def install_scheduler(%EditorState{} = state),
    do: %{state | effect_scheduler: start_scheduler()}

  @doc "Receives and claims the terminal copy outcome before applying it."
  @spec complete_copy(EditorState.t(), :completed | :failed) :: EditorState.t()
  def complete_copy(%EditorState{effect_scheduler: scheduler} = state, status \\ :completed) do
    outcome = take_copy(scheduler, status)
    {state, applied} = Copy.apply(state, outcome)
    EffectScheduler.finalize(scheduler, applied)
    state
  end

  @doc "Claims a terminal copy outcome for a test that controls when it is applied."
  @spec take_copy(EffectScheduler.server(), :completed | :failed) :: Outcome.t()
  def take_copy(scheduler, status) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %{handler: Copy}, value: {^status, _}} = outcome},
                   2_000

    assert :ok = EffectScheduler.claim(scheduler, outcome)
    outcome
  end
end
