defmodule Minga.Editor.Commands.Folding do
  @moduledoc """
  Fold commands: toggle, open, close, open all, close all.

  Operates on both per-window folds (code folds from `FoldMap`) and
  per-buffer decoration folds (from `Decorations`). Per-window folds
  take precedence when both types exist at the cursor line.
  """

  @behaviour Minga.Command.Provider

  alias Minga.Buffer
  alias Minga.Core.Decorations
  alias Minga.Editor.FoldMap
  alias Minga.Editing.Fold.Range, as: FoldRange
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
    case EditorState.active_window_struct(state) do
      nil -> state
      window -> dispatch_fold_command(state, window, :toggle)
    end
  end

  def execute(state, :fold_close) do
    case EditorState.active_window_struct(state) do
      nil -> state
      window -> dispatch_fold_command(state, window, :close)
    end
  end

  def execute(state, :fold_open) do
    case EditorState.active_window_struct(state) do
      nil -> state
      window -> dispatch_fold_command(state, window, :open)
    end
  end

  def execute(state, :fold_close_all) do
    state = update_active_window(state, &Window.fold_all/1)
    close_all_decoration_folds(state)
  end

  def execute(state, :fold_open_all) do
    state = update_active_window(state, &Window.unfold_all/1)
    open_all_decoration_folds(state)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec update_active_window(state(), (Window.t() -> Window.t())) :: state()
  defp update_active_window(%{workspace: %{windows: %{active: id}}} = state, fun)
       when is_integer(id) do
    EditorState.update_window(state, id, fun)
  end

  defp update_active_window(state, _fun), do: state

  # Dispatches a fold command at the cursor line. Checks both active folds
  # (already collapsed) and available fold ranges (from tree-sitter).
  # Falls back to decoration folds if no window fold range covers the line.
  @spec dispatch_fold_command(state(), Window.t(), :toggle | :close | :open) :: state()
  defp dispatch_fold_command(state, window, action) do
    {cursor_line, _col} = window.cursor

    has_active_fold = FoldMap.fold_at(window.fold_map, cursor_line) != :none
    has_available_range = Enum.any?(window.fold_ranges, &FoldRange.contains?(&1, cursor_line))

    if has_active_fold or has_available_range do
      apply_window_fold(state, window, cursor_line, action)
    else
      apply_decoration_fold(state, window.buffer, cursor_line, action)
    end
  end

  @spec apply_window_fold(state(), Window.t(), non_neg_integer(), :toggle | :close | :open) ::
          state()
  defp apply_window_fold(state, _window, cursor_line, :toggle) do
    update_active_window(state, fn w -> Window.toggle_fold(w, cursor_line) end)
  end

  defp apply_window_fold(state, _window, cursor_line, :close) do
    update_active_window(state, fn w -> Window.fold_at(w, cursor_line) end)
  end

  defp apply_window_fold(state, _window, cursor_line, :open) do
    update_active_window(state, fn w -> Window.unfold_at(w, cursor_line) end)
  end

  @spec apply_decoration_fold(state(), pid(), non_neg_integer(), :toggle | :close | :open) ::
          state()
  defp apply_decoration_fold(state, buf, cursor_line, action) do
    decs = Buffer.decorations(buf)

    case Decorations.fold_region_at(decs, cursor_line) do
      nil -> state
      fold -> maybe_toggle_decoration(state, buf, fold, action)
    end
  catch
    :exit, _ -> state
  end

  defp maybe_toggle_decoration(state, buf, %{id: id, closed: closed}, action) do
    should_act = should_toggle?(action, closed)

    if should_act do
      Buffer.batch_decorations(buf, fn d -> Decorations.toggle_fold_region(d, id) end)
    end

    state
  end

  defp should_toggle?(:toggle, _closed), do: true
  defp should_toggle?(:close, closed), do: not closed
  defp should_toggle?(:open, closed), do: closed

  @spec close_all_decoration_folds(state()) :: state()
  defp close_all_decoration_folds(state) do
    set_all_decoration_folds(state, :close)
  end

  @spec open_all_decoration_folds(state()) :: state()
  defp open_all_decoration_folds(state) do
    set_all_decoration_folds(state, :open)
  end

  defp set_all_decoration_folds(state, direction) do
    buf = state.workspace.buffers.active

    Buffer.batch_decorations(buf, fn decs ->
      Enum.reduce(decs.fold_regions, decs, fn fold, d ->
        toggle_if_needed(d, fold, direction)
      end)
    end)

    state
  catch
    :exit, _ -> state
  end

  defp toggle_if_needed(decs, fold, :close) do
    if fold.closed, do: decs, else: Decorations.toggle_fold_region(decs, fold.id)
  end

  defp toggle_if_needed(decs, fold, :open) do
    if fold.closed, do: Decorations.toggle_fold_region(decs, fold.id), else: decs
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
