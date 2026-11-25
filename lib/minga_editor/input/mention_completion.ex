defmodule MingaEditor.Input.MentionCompletion do
  @moduledoc """
  Input handler for @-mention file completion in the agent prompt.

  Active when `panel.mention_completion` is non-nil and the panel
  input is focused. Handles Tab (next), Shift+Tab (prev), Enter
  (accept), Escape (cancel), Backspace (narrow/cancel), and
  printable chars (narrow candidates).

  Enter with a modifier (⌥↩ queue, ⌘↩ send) is the composer's own key, not the popup's: it closes the completion and passes through, so a press right after typing a mention is never swallowed (#4260).
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Commands.Agent, as: AgentCommands

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  # Agent scope: mention completion active in insert mode
  def handle_key(%{workspace: %{keymap_scope: :agent}} = state, cp, mods) do
    panel = state.workspace.agent_ui.panel

    if panel.input_focused and panel.mention_completion != nil do
      complete_or_pass(state, cp, mods)
    else
      {:passthrough, state}
    end
  end

  # Editor scope: mention completion active in side panel
  def handle_key(%{workspace: %{keymap_scope: :editor}} = state, cp, mods) do
    panel = state.workspace.agent_ui.panel

    if panel.visible and panel.input_focused and panel.mention_completion != nil do
      complete_or_pass(state, cp, mods)
    else
      {:passthrough, state}
    end
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end

  @enter 13
  @escape 27
  @cmd 0x08

  # Modified Enter closes the popup and reaches the composer's binding.
  @spec complete_or_pass(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp complete_or_pass(state, @enter, mods) when mods != 0,
    do: {:passthrough, AgentCommands.handle_mention_key(state, @escape, 0)}

  # A ⌘ chord is the composer's or the agent's key, never text for the query: ⌘. must still stop the agent.
  defp complete_or_pass(state, cp, mods) when cp >= 32 and Bitwise.band(mods, @cmd) != 0,
    do: {:passthrough, AgentCommands.handle_mention_key(state, @escape, 0)}

  defp complete_or_pass(state, cp, mods),
    do: {:handled, AgentCommands.handle_mention_key(state, cp, mods)}
end
