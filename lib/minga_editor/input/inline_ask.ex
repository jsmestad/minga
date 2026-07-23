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
  def handle_key(state, codepoint, modifiers), do: handle_key(state, codepoint, modifiers, [])

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

  defp handle_inline_key(
         state,
         %InlineAsk{phase: {:answered, _response}} = ask,
         9,
         _modifiers,
         _opts
       ),
       do: InlineAskCommand.promote(state, ask)

  defp handle_inline_key(
         state,
         %InlineAsk{phase: {:answered, _response}} = ask,
         codepoint,
         _modifiers,
         opts
       )
       when codepoint in [?j, ?k],
       do: Overlay.update(state, InlineAsk.scroll(ask, scroll_delta(codepoint)), spec(opts))

  defp handle_inline_key(
         state,
         %InlineAsk{phase: {:failed, _message}} = ask,
         codepoint,
         _modifiers,
         opts
       )
       when codepoint in [?j, ?k],
       do: Overlay.update(state, InlineAsk.scroll(ask, scroll_delta(codepoint)), spec(opts))

  defp handle_inline_key(state, %InlineAsk{phase: :input} = ask, 13, _modifiers, opts),
    do: Overlay.submit(state, ask, "Type a question first", spec(opts))

  defp handle_inline_key(state, %InlineAsk{phase: :input} = ask, codepoint, _modifiers, opts)
       when codepoint in [127, 8],
       do: Overlay.backspace(state, ask, spec(opts))

  defp handle_inline_key(state, %InlineAsk{phase: :input} = ask, codepoint, modifiers, opts)
       when codepoint >= 32,
       do: Overlay.append_printable(state, ask, codepoint, modifiers, spec(opts))

  defp handle_inline_key(state, _ask, _codepoint, _modifiers, _opts), do: state

  defp scroll_delta(?j), do: 1
  defp scroll_delta(?k), do: -1

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
      session_pid: &InlineAsk.session_pid/1,
      fail_prefix: "Failed to start inline ask: "
    }
  end
end
