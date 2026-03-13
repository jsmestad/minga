defmodule Minga.Editor.Commands.Folding do
  @moduledoc """
  Fold commands: toggle, open, close, open all, close all.

  All commands operate on the active window's fold state. The fold map
  and available fold ranges live in the Window struct, not the buffer.
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Window

  @type state :: EditorState.t()

  @typedoc "Fold command atoms."
  @type fold_command :: :fold_toggle | :fold_close | :fold_open | :fold_close_all | :fold_open_all

  @doc """
  Executes a fold command on the active window.

  - `:fold_toggle` — toggles the fold at the cursor line (za)
  - `:fold_close` — closes (folds) the range at the cursor line (zc)
  - `:fold_open` — opens (unfolds) the fold at the cursor line (zo)
  - `:fold_close_all` — closes all folds in the active window (zM)
  - `:fold_open_all` — opens all folds in the active window (zR)
  """
  @spec execute(state(), fold_command()) :: state()
  def execute(state, :fold_toggle) do
    update_active_window(state, fn window ->
      {cursor_line, _col} = window.cursor
      Window.toggle_fold(window, cursor_line)
    end)
  end

  def execute(state, :fold_close) do
    update_active_window(state, fn window ->
      {cursor_line, _col} = window.cursor
      Window.fold_at(window, cursor_line)
    end)
  end

  def execute(state, :fold_open) do
    update_active_window(state, fn window ->
      {cursor_line, _col} = window.cursor
      Window.unfold_at(window, cursor_line)
    end)
  end

  def execute(state, :fold_close_all) do
    update_active_window(state, &Window.fold_all/1)
  end

  def execute(state, :fold_open_all) do
    update_active_window(state, &Window.unfold_all/1)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec update_active_window(state(), (Window.t() -> Window.t())) :: state()
  defp update_active_window(%{windows: %{active: id}} = state, fun) when is_integer(id) do
    EditorState.update_window(state, id, fun)
  end

  defp update_active_window(state, _fun), do: state
end
