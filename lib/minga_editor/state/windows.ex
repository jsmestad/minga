defmodule MingaEditor.State.Windows do
  @moduledoc """
  Groups window-related fields from EditorState.

  Tracks the window tree layout, the map of window structs, the active
  window id, and the next available window id for splits.
  """

  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @type t :: %__MODULE__{
          tree: WindowTree.t() | nil,
          map: %{Window.id() => Window.t()},
          active: Window.id(),
          next_id: Window.id()
        }

  defstruct tree: nil,
            map: %{},
            active: 1,
            next_id: 2

  @doc "Returns the active window struct, or nil if no windows are initialized."
  @spec active_struct(t()) :: Window.t() | nil
  def active_struct(%__MODULE__{map: windows, active: id}) do
    Map.get(windows, id)
  end

  @doc "Returns true if the window tree contains a split."
  @spec split?(t()) :: boolean()
  def split?(%__MODULE__{tree: nil}), do: false
  def split?(%__MODULE__{tree: {:leaf, _}}), do: false
  def split?(%__MODULE__{tree: {:split, _, _, _, _}}), do: true

  @doc """
  Updates the window struct for the given window id.

  Applies the given function to the window and stores the result.
  Returns the struct unchanged if the id is not found.
  """
  @spec update(t(), Window.id(), (Window.t() -> Window.t())) :: t()
  def update(%__MODULE__{map: windows} = win, id, fun) when is_function(fun, 1) do
    case Map.fetch(windows, id) do
      {:ok, window} -> %{win | map: Map.put(windows, id, fun.(window))}
      :error -> win
    end
  end

  @doc """
  Returns all popup windows as a list of `{window_id, window}` tuples.

  Popup windows are those with a non-nil `popup_meta` field.
  """
  @spec popup_windows(t()) :: [{Window.id(), Window.t()}]
  def popup_windows(%__MODULE__{map: windows}) do
    Enum.filter(windows, fn {_id, window} -> Window.popup?(window) end)
  end
end
