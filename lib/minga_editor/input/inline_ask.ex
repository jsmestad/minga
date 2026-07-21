defmodule MingaEditor.Input.InlineAsk do
  @moduledoc """
  Input handler for the active inline ask overlay.

  This is the ask variant adapter over the shared
  `MingaEditor.Input.InlineOverlay` plumbing: it supplies the store
  accessor/setter and the ask-specific key table (Esc dismiss, Tab promote,
  j/k scroll), and delegates the active lookup, submit, and dismissal to the
  framework.
  """

  @behaviour MingaEditor.Input.Handler

  alias MingaAgent.EphemeralSession
  alias MingaEditor.Commands.InlineAsk, as: InlineAskCommand
  alias MingaEditor.Input.InlineOverlay, as: Overlay
  alias MingaEditor.State.InlineAsk

  @type state :: MingaEditor.Input.Handler.handler_state()

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, codepoint, modifiers) do
    handle_key(state, codepoint, modifiers, [])
  end

  @doc false
  @spec handle_key(state(), non_neg_integer(), non_neg_integer(), keyword()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(state, codepoint, modifiers, opts) when is_list(opts) do
    case Overlay.active(state, spec(opts)) do
      %InlineAsk{} = ask -> {:handled, handle_inline_key(state, ask, codepoint, modifiers, opts)}
      nil -> {:passthrough, state}
    end
  end

  @spec handle_inline_key(state(), InlineAsk.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
          state()
  defp handle_inline_key(state, ask, 27, _modifiers, opts),
    do: Overlay.dismiss(state, ask, spec(opts))

  defp handle_inline_key(state, %InlineAsk{status: :answered} = ask, 9, _modifiers, _opts),
    do: InlineAskCommand.promote(state, ask)

  defp handle_inline_key(state, %InlineAsk{status: status} = ask, ?j, _modifiers, opts)
       when status in [:answered, :error],
       do: Overlay.update(state, InlineAsk.scroll(ask, 1), spec(opts))

  defp handle_inline_key(state, %InlineAsk{status: status} = ask, ?k, _modifiers, opts)
       when status in [:answered, :error],
       do: Overlay.update(state, InlineAsk.scroll(ask, -1), spec(opts))

  defp handle_inline_key(state, %InlineAsk{status: :input} = ask, 13, _modifiers, opts),
    do: Overlay.submit(state, ask, "Type a question first", spec(opts))

  defp handle_inline_key(state, %InlineAsk{status: :input} = ask, 127, _modifiers, opts),
    do: Overlay.backspace(state, ask, spec(opts))

  defp handle_inline_key(state, %InlineAsk{status: :input} = ask, 8, _modifiers, opts),
    do: Overlay.backspace(state, ask, spec(opts))

  defp handle_inline_key(state, %InlineAsk{status: :input} = ask, codepoint, modifiers, opts)
       when codepoint >= 32,
       do: Overlay.append_printable(state, ask, codepoint, modifiers, spec(opts))

  defp handle_inline_key(state, _ask, _codepoint, _modifiers, _opts), do: state

  @spec spec(keyword()) :: Overlay.spec()
  defp spec(opts) do
    %{
      store: fn state ->
        MingaEditor.Shell.Traditional.State.inline_asks(state.shell_runtime.state)
      end,
      replace: &MingaEditor.Shell.Traditional.Workflow.install_inline_ask/2,
      cancel: &MingaEditor.Shell.Traditional.Workflow.cancel_inline_ask/2,
      state_module: InlineAsk,
      session_starter: Keyword.get(opts, :session_asker, &EphemeralSession.ask/3),
      fail_prefix: "Failed to start inline ask: "
    }
  end
end
