defmodule MingaEditor.Input.SignatureHelp do
  @moduledoc """
  Input handler for signature help overlay.

  When signature help is visible, intercepts C-j/C-k to cycle through
  overloaded signatures and Escape to dismiss. All other keys pass
  through (signature help stays visible while typing arguments).
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Shell.Traditional.SignatureHelpWorkflow
  alias MingaEditor.SignatureHelp, as: SigHelp

  import Bitwise

  @ctrl MingaEditor.Input.mod_ctrl()
  @key_escape 27

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{shell_runtime: %{state: %{signature_help: nil}}} = state, _cp, _mods) do
    {:passthrough, state}
  end

  # C-j: next signature overload
  def handle_key(%{shell_runtime: %{state: %{signature_help: %SigHelp{}}}} = state, ?j, mods)
      when band(mods, @ctrl) != 0 do
    {:handled, SignatureHelpWorkflow.next(state)}
  end

  # C-k: previous signature overload
  def handle_key(%{shell_runtime: %{state: %{signature_help: %SigHelp{}}}} = state, ?k, mods)
      when band(mods, @ctrl) != 0 do
    {:handled, SignatureHelpWorkflow.previous(state)}
  end

  # Escape: dismiss signature help
  def handle_key(
        %{shell_runtime: %{state: %{signature_help: %SigHelp{}}}} = state,
        @key_escape,
        _mods
      ) do
    {:handled, SignatureHelpWorkflow.dismiss(state)}
  end

  # All other keys: pass through (signature help stays visible while typing)
  def handle_key(state, _cp, _mods) do
    {:passthrough, state}
  end
end
