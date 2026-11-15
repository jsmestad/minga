defmodule MingaEditor.Input.AgentHelp do
  @moduledoc "Consumes covered editing input while Agent Help is visible without changing its underlying focus."

  @behaviour MingaEditor.Input.Handler

  alias MingaEditor.Commands.Agent, as: AgentCommands

  @type state :: MingaEditor.Input.Handler.handler_state()

  @doc "Reports whether the committed workspace Help presentation covers input."
  @spec active?(state() | MingaEditor.RenderPipeline.Input.t()) :: boolean()
  def active?(%{workspace: %{agent_ui: %{view: %{help_visible: true}}}}), do: true
  def active?(_state), do: false

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, codepoint, modifiers) do
    if active?(state),
      do: handle_help_key(state, codepoint, modifiers),
      else: {:passthrough, state}
  end

  @impl true
  @spec handle_paste(state(), String.t()) :: MingaEditor.Input.Handler.result()
  def handle_paste(state, _text) do
    if active?(state), do: {:handled, state}, else: {:passthrough, state}
  end

  @spec handle_help_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp handle_help_key(state, codepoint, 0) when codepoint in [27, ??],
    do: {:handled, AgentCommands.scope_dismiss_help(state)}

  defp handle_help_key(state, _codepoint, _modifiers), do: {:handled, state}
end
