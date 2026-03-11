defmodule Minga.Input.MentionCompletion do
  @moduledoc """
  Input handler for @-mention file completion in the agent prompt.

  Active when `panel.mention_completion` is non-nil and the panel
  input is focused. Handles Tab (next), Shift+Tab (prev), Enter
  (accept), Escape (cancel), Backspace (narrow/cancel), and
  printable chars (narrow candidates).
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  # Agent scope: mention completion active in insert mode
  def handle_key(
        %{
          keymap_scope: :agent,
          agent: %{panel: %{input_focused: true, mention_completion: comp}}
        } = state,
        cp,
        mods
      )
      when comp != nil do
    {:handled, AgentCommands.handle_mention_key(state, cp, mods)}
  end

  # Editor scope: mention completion active in side panel
  def handle_key(
        %{
          keymap_scope: :editor,
          agent: %{panel: %{visible: true, input_focused: true, mention_completion: comp}}
        } = state,
        cp,
        mods
      )
      when comp != nil do
    {:handled, AgentCommands.handle_mention_key(state, cp, mods)}
  end

  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
