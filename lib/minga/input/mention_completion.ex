defmodule Minga.Input.MentionCompletion do
  @moduledoc """
  Input handler for @-mention file completion in the agent prompt.

  Active when `panel.mention_completion` is non-nil and the panel
  input is focused. Handles Tab (next), Shift+Tab (prev), Enter
  (accept), Escape (cancel), Backspace (narrow/cancel), and
  printable chars (narrow candidates).
  """

  @behaviour Minga.Input.Handler

  @type state :: Minga.Input.Handler.handler_state()

  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State.AgentAccess

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) :: Minga.Input.Handler.result()

  # Agent scope: mention completion active in insert mode
  def handle_key(%{workspace: %{keymap_scope: :agent}} = state, cp, mods) do
    panel = AgentAccess.panel(state)

    if panel.input_focused and panel.mention_completion != nil do
      {:handled, AgentCommands.handle_mention_key(state, cp, mods)}
    else
      {:passthrough, state}
    end
  end

  # Editor scope: mention completion active in side panel
  def handle_key(%{workspace: %{keymap_scope: :editor}} = state, cp, mods) do
    panel = AgentAccess.panel(state)

    if panel.visible and panel.input_focused and panel.mention_completion != nil do
      {:handled, AgentCommands.handle_mention_key(state, cp, mods)}
    else
      {:passthrough, state}
    end
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
