defmodule MingaEditor.Shell.Traditional.ToolPromptWorkflow do
  @moduledoc """
  Focused boundary for Traditional missing-tool prompt lifecycle.

  Tool-manager process queries stay here; the shell value only records queue,
  suppression, and session-local decisions.
  """

  alias Minga.Tool.Manager, as: ToolManager
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.ToolPrompts
  alias MingaEditor.State, as: EditorState

  @type state :: EditorState.t()

  @doc "Returns the current prompt owner, or defaults outside Traditional."
  @spec prompts(state()) :: ToolPrompts.t()
  def prompts(%EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}}),
    do: TraditionalState.tool_prompts(shell_state)

  def prompts(%EditorState{}), do: %ToolPrompts{}

  @doc "Returns whether a missing tool should not produce another prompt."
  @spec skip?(state(), atom()) :: boolean()
  def skip?(
        %EditorState{shell_runtime: %Runtime{state: %TraditionalState{} = shell_state}},
        tool_name
      ) do
    TraditionalState.tool_prompt_decided?(shell_state, tool_name) or
      ToolManager.installed?(tool_name) or
      MapSet.member?(ToolManager.installing(), tool_name)
  end

  def skip?(%EditorState{}, _tool_name), do: true

  @doc "Controls whether missing-tool prompts are suppressed."
  @spec suppress(state(), boolean()) :: state()
  def suppress(%EditorState{} = state, suppressed?) when is_boolean(suppressed?),
    do: update(state, &TraditionalState.set_suppress_tool_prompts(&1, suppressed?))

  @doc "Queues a missing tool once."
  @spec enqueue(state(), atom()) :: state()
  def enqueue(%EditorState{} = state, tool_name),
    do: update(state, &TraditionalState.enqueue_tool_prompt(&1, tool_name))

  @doc "Replaces pending queue and declined decisions atomically."
  @spec replace(state(), [atom()], MapSet.t(atom())) :: state()
  def replace(%EditorState{} = state, queue, declined),
    do: update(state, &TraditionalState.replace_tool_prompts(&1, queue, declined))

  @doc "Drops the current pending prompt."
  @spec advance(state()) :: state()
  def advance(%EditorState{} = state),
    do: update(state, &TraditionalState.advance_tool_prompt/1)

  @spec update(state(), (TraditionalState.t() -> TraditionalState.t())) :: state()
  defp update(%EditorState{} = state, transition) do
    runtime = Runtime.update_traditional_state(state.shell_runtime, transition)
    EditorState.apply_shell_runtime_transition(state, runtime)
  end
end
