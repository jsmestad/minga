defmodule MingaEditor.Handlers.ToolHandler do
  @moduledoc """
  Pure handler for tool installation/management events.

  Extracts the 8 `handle_info` clauses for tool events from the Editor
  GenServer into pure `{state, [effect]}` functions. The Editor delegates
  to this module via catch-all clauses and applies the returned effects.

  Each function reads and writes only tool-related state slices
  (`state.shell_state.tool_prompt_queue`, `state.shell_state.tool_declined`,
  status messages).
  """

  alias MingaEditor.State, as: EditorState

  @typedoc "Effects that the tool handler may return."
  @type tool_effect ::
          :render
          | {:log_message, String.t()}
          | {:log, atom(), atom(), String.t()}
          | {:set_status, String.t()}
          | :clear_status
          | {:refresh_tool_picker}
          | {:send_after, term(), non_neg_integer()}
          | {:transition_mode, atom(), term()}

  @doc """
  Dispatches a tool event to the appropriate handler.

  Returns `{state, effects}` where effects encode all side-effectful
  operations.
  """
  @spec handle(EditorState.t(), term()) :: {EditorState.t(), [tool_effect()]}

  def handle(state, {:minga_event, :tool_install_started, %{name: name}}) do
    new_state = EditorState.set_status(state, "Installing #{name}...")
    {new_state, [{:refresh_tool_picker}, :render]}
  end

  def handle(state, {:minga_event, :tool_install_progress, %{name: name, message: msg}}) do
    new_state = EditorState.set_status(state, "#{name}: #{msg}")
    {new_state, [:render]}
  end

  def handle(state, {:minga_event, :tool_install_complete, %{name: name, version: version}}) do
    new_state = EditorState.set_status(state, "\u2713 #{name} v#{version} installed")

    effects = [
      {:log_message, "Tool installed: #{name} v#{version}"},
      {:refresh_tool_picker},
      :render
    ]

    # Schedule status clear after 5 seconds (skip in headless)
    effects =
      if state.backend != :headless do
        effects ++ [{:send_after, :clear_tool_status, 5_000}]
      else
        effects
      end

    {new_state, effects}
  end

  def handle(state, {:minga_event, :tool_install_failed, %{name: name, reason: reason}}) do
    reason_str = if is_binary(reason), do: reason, else: inspect(reason)
    new_state = EditorState.set_status(state, "\u2715 #{name} install failed: #{reason_str}")

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
    current = EditorState.status_msg(state) || ""

    new_state =
      if String.starts_with?(current, [
           "\u2713 ",
           "Installing ",
           "Updating "
         ]) do
        EditorState.clear_status(state)
      else
        state
      end

    {new_state, [:render]}
  end

  # ── Tool missing prompt (suppressed) ─────────────────────────────────────

  def handle(
        %{shell_state: %{suppress_tool_prompts: true}} = state,
        {:minga_event, :tool_missing, %Minga.Events.ToolMissingEvent{command: command}}
      ) do
    {state, [{:log, :editor, :debug, "[Editor] tool_missing suppressed for #{command}"}]}
  end

  # ── Tool missing prompt (active) ─────────────────────────────────────────

  def handle(
        state,
        {:minga_event, :tool_missing, %Minga.Events.ToolMissingEvent{command: command}}
      ) do
    recipe = Minga.Tool.Recipe.Registry.for_command(command)

    new_state =
      if recipe && not EditorState.skip_tool_prompt?(state, recipe.name) do
        queue = state.shell_state.tool_prompt_queue ++ [recipe.name]

        state_with_queue =
          EditorState.update_shell_state(state, &%{&1 | tool_prompt_queue: queue})

        maybe_show_tool_prompt(state_with_queue)
      else
        state
      end

    {new_state, [:render]}
  end

  # ── Catch-all ────────────────────────────────────────────────────────────

  def handle(state, _msg) do
    {state, []}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  # Transitions to :tool_confirm mode if in normal mode and there are
  # pending tool prompts. Otherwise the prompt waits until the user
  # returns to normal mode.
  @spec maybe_show_tool_prompt(EditorState.t()) :: EditorState.t()
  defp maybe_show_tool_prompt(
         %{workspace: %{editing: %{mode: :normal}}, shell_state: %{tool_prompt_queue: pending}} =
           state
       )
       when pending != [] do
    ms = %Minga.Mode.ToolConfirmState{pending: pending, declined: state.shell_state.tool_declined}
    EditorState.transition_mode(state, :tool_confirm, ms)
  end

  defp maybe_show_tool_prompt(state), do: state
end
