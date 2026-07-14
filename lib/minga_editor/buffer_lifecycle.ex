defmodule MingaEditor.BufferLifecycle do
  @moduledoc """
  Post-command lifecycle helpers for the Editor.

  Buffer processes publish authoritative `:buffer_saved` events after every
  successful explicit or automatic write. This post-command hook remains as a
  compatibility boundary for command dispatch, but does not duplicate those
  source-owned events.
  """

  alias MingaEditor.State, as: EditorState
  alias Minga.Mode

  @type state :: EditorState.t()

  @doc "Runs post-command lifecycle actions."
  @spec lsp_after_command(state(), Mode.command(), pid() | nil) :: state()
  def lsp_after_command(state, _cmd, _old_buffer), do: state

  @doc "Returns state unchanged; successful saves publish from the buffer process."
  @spec lsp_after_save(state(), Mode.command()) :: state()
  def lsp_after_save(state, _cmd), do: state

  @doc "Returns state unchanged; successful saves publish from the buffer process."
  @spec lsp_after_save(state(), Mode.command(), pid()) :: state()
  def lsp_after_save(state, _cmd, _buf), do: state
end
