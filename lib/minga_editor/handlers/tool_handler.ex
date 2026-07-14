defmodule MingaEditor.Handlers.ToolHandler do
  @moduledoc """
  Owns tool installation/management transitions and external actions.

  `dispatch/2` updates tool prompts/notices first, then applies focused actions
  in list order. Picker refreshes, logs, renders, and the clear-status timer run
  in the Editor process, so the same process creates and receives timer
  messages. Installer supervision remains with the tool service; this workflow
  only presents its ordered events. Unknown/stale events are ignored, install
  failures are logged and rendered, and headless mode creates no timer.
  """

  alias MingaEditor.Shell.Traditional.ToolPrompts
  alias MingaEditor.Shell.Traditional.ToolPromptWorkflow
  alias MingaEditor.State, as: EditorState

  @typedoc "Effects that the tool handler may return."
  @type tool_effect ::
          :render
          | {:log_message, String.t()}
          | {:log, atom(), :debug | :info | :warning | :error, String.t()}
          | {:refresh_tool_picker}
          | {:send_after, term(), non_neg_integer()}

  @doc "Applies one tool event and its focused actions."
  @spec dispatch(EditorState.t(), term()) :: EditorState.t()
  def dispatch(%EditorState{} = state, message) do
    {state, effects} = handle(state, message)
    apply_effects(state, effects)
  end

  @doc """
  Dispatches a tool event to the appropriate handler.

  Returns `{state, effects}` where effects encode all side-effectful
  operations.
  """
  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [tool_effect()]}

  def handle(state, {:minga_event, :tool_install_started, %{name: name}}) do
    new_state =
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "Installing #{name}...")

    {new_state, [{:refresh_tool_picker}, :render]}
  end

  def handle(state, {:minga_event, :tool_install_progress, %{name: name, message: msg}}) do
    new_state = MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, "#{name}: #{msg}")
    {new_state, [:render]}
  end

  def handle(state, {:minga_event, :tool_install_complete, %{name: name, version: version}}) do
    new_state =
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
        state,
        "\u2713 #{name} v#{version} installed"
      )

    effects = [
      {:log_message, "Tool installed: #{name} v#{version}"},
      {:refresh_tool_picker},
      :render
    ]

    # Schedule status clear after 5 seconds (skip in headless)
    effects =
      if state.frontend.backend != :headless do
        Enum.concat(effects, [{:send_after, :clear_tool_status, 5_000}])
      else
        effects
      end

    {new_state, effects}
  end

  def handle(state, {:minga_event, :tool_install_failed, %{name: name, reason: reason}}) do
    reason_str = if is_binary(reason), do: reason, else: inspect(reason)

    new_state =
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
        state,
        "\u2715 #{name} install failed: #{reason_str}"
      )

    {new_state,
     [
       {:log_message, "Tool install failed: #{name} \u2014 #{reason_str}"},
       {:refresh_tool_picker},
       :render
     ]}
  end

  def handle(state, {:minga_event, :tool_uninstall_complete, %{name: name}}) do
    {state,
     [
       {:log_message, "Tool uninstalled: #{name}"},
       {:refresh_tool_picker},
       :render
     ]}
  end

  def handle(state, :clear_tool_status) do
    current = MingaEditor.Shell.Traditional.NoticeWorkflow.message(state) || ""

    new_state =
      if String.starts_with?(current, [
           "\u2713 ",
           "Installing ",
           "Updating "
         ]) do
        MingaEditor.Shell.Traditional.NoticeWorkflow.dismiss(state)
      else
        state
      end

    {new_state, [:render]}
  end

  # ── Tool missing prompt ──────────────────────────────────────────────────

  def handle(
        state,
        {:minga_event, :tool_missing, %Minga.Events.ToolMissingEvent{command: command}}
      ) do
    prompts = ToolPromptWorkflow.prompts(state)
    handle_tool_missing(state, command, ToolPrompts.suppressed?(prompts))
  end

  # ── Catch-all ────────────────────────────────────────────────────────────

  def handle(state, _msg) do
    {state, []}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec apply_effects(EditorState.t(), [tool_effect()]) :: EditorState.t()
  defp apply_effects(state, []), do: state

  defp apply_effects(state, [effect | rest]) do
    state = apply_effect(state, effect)
    apply_effects(state, rest)
  end

  @spec apply_effect(EditorState.t(), tool_effect()) :: EditorState.t()
  defp apply_effect(state, :render), do: MingaEditor.schedule_render(state, 16)

  defp apply_effect(state, {:log_message, message}) do
    Minga.Log.info(:editor, message)
    state
  end

  defp apply_effect(state, {:log, subsystem, level, message}) do
    log(subsystem, level, message)
    state
  end

  defp apply_effect(state, {:refresh_tool_picker}),
    do: MingaEditor.maybe_refresh_tool_picker(state)

  defp apply_effect(state, {:send_after, message, delay_ms}) do
    if state.frontend.backend != :headless, do: Process.send_after(self(), message, delay_ms)
    state
  end

  @spec log(atom(), :debug | :info | :warning | :error, String.t()) :: :ok
  defp log(subsystem, :debug, message), do: Minga.Log.debug(subsystem, message)
  defp log(subsystem, :info, message), do: Minga.Log.info(subsystem, message)
  defp log(subsystem, :warning, message), do: Minga.Log.warning(subsystem, message)
  defp log(subsystem, :error, message), do: Minga.Log.error(subsystem, message)

  @spec handle_tool_missing(EditorState.t(), String.t(), boolean()) ::
          {EditorState.t(), [tool_effect()]}
  defp handle_tool_missing(state, command, true) do
    {state, [{:log, :editor, :debug, "[Editor] tool_missing suppressed for #{command}"}]}
  end

  defp handle_tool_missing(state, command, false) do
    recipe = Minga.Tool.Recipe.Registry.for_command(command)

    new_state =
      if recipe && not ToolPromptWorkflow.skip?(state, recipe.name) do
        state
        |> ToolPromptWorkflow.enqueue(recipe.name)
        |> maybe_show_tool_prompt()
      else
        state
      end

    {new_state, [:render]}
  end

  # Transitions to :tool_confirm mode if in normal mode and there are
  # pending tool prompts. Otherwise the prompt waits until the user
  # returns to normal mode.
  @spec maybe_show_tool_prompt(EditorState.t()) :: EditorState.t()
  defp maybe_show_tool_prompt(%{workspace: %{editing: %{mode: :normal}}} = state) do
    prompts = ToolPromptWorkflow.prompts(state)
    show_tool_prompt(state, ToolPrompts.queue(prompts), ToolPrompts.declined(prompts))
  end

  defp maybe_show_tool_prompt(state), do: state

  @spec show_tool_prompt(EditorState.t(), [atom()], MapSet.t(atom())) :: EditorState.t()
  defp show_tool_prompt(state, [], _declined), do: state

  defp show_tool_prompt(state, pending, declined) do
    %{
      state
      | workspace:
          MingaEditor.Session.State.transition_mode(
            state.workspace,
            :tool_confirm,
            %Minga.Mode.ToolConfirmState{pending: pending, declined: declined}
          )
    }
  end
end
