defmodule Minga.Input.Popup do
  @moduledoc """
  Input handler for popup window dismissal.

  Active when the focused window has `popup_meta` set (it's a popup).
  Intercepts the quit key (default `q` in normal mode) and closes the
  popup, restoring the previous layout. All other keys pass through to
  the normal input pipeline so the popup buffer is navigable.

  This handler sits in the surface handler list, before Scoped, so it
  intercepts the quit key before normal mode processes it as a recording
  command.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Window
  alias Minga.Popup.Lifecycle

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  def handle_key(state, codepoint, _modifiers) do
    case active_popup_meta(state) do
      nil ->
        {:passthrough, state}

      meta ->
        # Only intercept the quit key in normal mode (not insert mode)
        if Minga.Editor.Editing.mode(state) == :normal and
             matches_quit_key?(meta.rule.quit_key, codepoint) do
          {:handled, Lifecycle.close_active_popup(state)}
        else
          {:passthrough, state}
        end
    end
  end

  @impl true
  @spec handle_mouse(
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  def handle_mouse(state, row, col, :left, _mods, :press, _cc) do
    # Check if any float popups are visible. Clicks outside their box
    # dismiss them; clicks inside are passed through to the buffer.
    case find_float_popup_id(state) do
      nil ->
        {:passthrough, state}

      popup_id ->
        if Lifecycle.click_inside_float?(state, row, col) do
          {:passthrough, state}
        else
          {:handled, Lifecycle.close_popup(state, popup_id)}
        end
    end
  end

  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _cc) do
    {:passthrough, state}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec find_float_popup_id(EditorState.t()) :: integer() | nil
  defp find_float_popup_id(%{workspace: %{windows: %{map: map}}}) do
    Enum.find_value(map, fn
      {id, %Window{popup_meta: %Minga.Popup.Active{rule: %Minga.Popup.Rule{display: :float}}}} ->
        id

      _ ->
        nil
    end)
  end

  @spec active_popup_meta(EditorState.t()) :: Minga.Popup.Active.t() | nil
  defp active_popup_meta(%{workspace: %{windows: %{map: map, active: active_id}}}) do
    case Map.fetch(map, active_id) do
      {:ok, %Window{popup_meta: meta}} -> meta
      _ -> nil
    end
  end

  @spec matches_quit_key?(String.t(), non_neg_integer()) :: boolean()
  defp matches_quit_key?(quit_key, codepoint) when is_binary(quit_key) do
    # Convert the quit key string to a codepoint for comparison.
    # Supports single-character keys like "q", "x", etc.
    case quit_key do
      <<char::utf8>> -> char == codepoint
      _ -> false
    end
  end
end
