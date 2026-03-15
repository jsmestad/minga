defmodule Minga.Editor.Commands.Folding do
  @moduledoc """
  Fold commands: toggle, open, close, open all, close all.

  All commands operate on the active window's fold state. The fold map
  and available fold ranges live in the Window struct, not the buffer.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.FoldMap
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Window

  @type state :: EditorState.t()

  @typedoc "Fold command atoms."
  @type fold_command :: :fold_toggle | :fold_close | :fold_open | :fold_close_all | :fold_open_all

  @command_specs [
    {:fold_toggle, "Toggle fold at cursor (za)", true},
    {:fold_close, "Close fold at cursor (zc)", true},
    {:fold_open, "Open fold at cursor (zo)", true},
    {:fold_close_all, "Close all folds (zM)", true},
    {:fold_open_all, "Open all folds (zR)", true}
  ]

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
    # Per-window folds take precedence. If the cursor is on a per-window
    # fold, toggle that. Otherwise check for a decoration fold.
    case EditorState.active_window_struct(state) do
      nil -> state
      window -> toggle_fold_at_cursor(state, window)
    end
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

  @spec toggle_fold_at_cursor(state(), Window.t()) :: state()
  defp toggle_fold_at_cursor(state, window) do
    {cursor_line, _col} = window.cursor

    case FoldMap.fold_at(window.fold_map, cursor_line) do
      {:ok, _range} ->
        update_active_window(state, fn w -> Window.toggle_fold(w, cursor_line) end)

      :none ->
        toggle_decoration_fold_on_buffer(window.buffer)
        state
    end
  end

  @spec toggle_decoration_fold_on_buffer(pid()) :: :ok
  defp toggle_decoration_fold_on_buffer(buf) do
    {cursor_line, _} = BufferServer.cursor(buf)
    decs = BufferServer.decorations(buf)

    case Decorations.fold_region_at(decs, cursor_line) do
      nil ->
        :ok

      fold ->
        BufferServer.batch_decorations(buf, fn d -> Decorations.toggle_fold_region(d, fold.id) end)
    end
  catch
    :exit, _ -> :ok
  end

  @impl Minga.Command.Provider
  def __commands__ do
    Enum.map(@command_specs, fn {name, desc, requires_buffer} ->
      %Minga.Command{
        name: name,
        description: desc,
        requires_buffer: requires_buffer,
        execute: fn state -> execute(state, name) end
      }
    end)
  end
end
