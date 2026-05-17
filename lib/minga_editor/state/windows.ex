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

  @doc "Replaces the window layout tree."
  @spec set_tree(t(), WindowTree.t() | nil) :: t()
  def set_tree(%__MODULE__{} = windows, tree) do
    %{windows | tree: tree}
  end

  @doc "Sets the active window id."
  @spec set_active(t(), Window.id()) :: t()
  def set_active(%__MODULE__{} = windows, id), do: %{windows | active: id}

  @doc "Replaces the window map."
  @spec set_map(t(), %{Window.id() => Window.t()}) :: t()
  def set_map(%__MODULE__{} = windows, map) when is_map(map), do: %{windows | map: map}

  @doc "Sets the next available window id."
  @spec set_next_id(t(), Window.id()) :: t()
  def set_next_id(%__MODULE__{} = windows, id), do: %{windows | next_id: id}

  @doc "Allocates the next window id and advances the allocator."
  @spec allocate_id(t()) :: {Window.id(), t()}
  def allocate_id(%__MODULE__{next_id: id} = windows) do
    {id, set_next_id(windows, id + 1)}
  end

  @doc "Adds a window to the container using the window's id."
  @spec add_window(t(), Window.t()) :: t()
  def add_window(%__MODULE__{map: map} = windows, %Window{id: id} = window) do
    set_map(windows, Map.put(map, id, window))
  end

  @doc "Removes a tree-managed window from the container."
  @spec remove_window(t(), Window.id()) :: {:ok, t()} | :error
  def remove_window(%__MODULE__{tree: nil}, _id), do: :error

  def remove_window(%__MODULE__{tree: tree} = windows, id) do
    case WindowTree.close(tree, id) do
      {:ok, new_tree} ->
        {:ok,
         windows
         |> set_tree(new_tree)
         |> delete_window(id)}

      :error ->
        :error
    end
  end

  @doc "Deletes a window from the map without touching the window tree."
  @spec delete_window(t(), Window.id()) :: t()
  def delete_window(%__MODULE__{map: map} = windows, id) do
    set_map(windows, Map.delete(map, id))
  end

  @doc "Fetches a window by id."
  @spec fetch(t(), Window.id()) :: {:ok, Window.t()} | :error
  def fetch(%__MODULE__{map: map}, id), do: Map.fetch(map, id)

  @doc "Finds the first window matching the given predicate."
  @spec find_by_content(t(), (Window.t() -> boolean())) :: {Window.id(), Window.t()} | nil
  def find_by_content(%__MODULE__{map: map}, predicate) when is_function(predicate, 1) do
    Enum.find(map, fn {_id, window} -> predicate.(window) end)
  end

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

  @doc "Updates every window that shows the given buffer pid via a mapper function."
  @spec update_by_buffer(t(), pid(), (Window.t() -> Window.t())) :: t()
  def update_by_buffer(%__MODULE__{map: windows} = win, buffer, fun)
      when is_pid(buffer) and is_function(fun, 1) do
    %{win | map: Enum.reduce(windows, windows, &update_by_buffer(buffer, fun, &1, &2))}
  end

  defp update_by_buffer(buffer, fun, {id, %Window{buffer: buffer}}, acc) do
    case Map.fetch(acc, id) do
      {:ok, current} -> Map.put(acc, id, fun.(current))
      :error -> acc
    end
  end

  defp update_by_buffer(_buffer, _fun, _entry, acc), do: acc

  @doc """
  Returns all popup windows as a list of `{window_id, window}` tuples.

  Popup windows are those with a non-nil `popup_meta` field.
  """
  @spec popup_windows(t()) :: [{Window.id(), Window.t()}]
  def popup_windows(%__MODULE__{map: windows}) do
    Enum.filter(windows, fn {_id, window} -> Window.popup?(window) end)
  end
end
