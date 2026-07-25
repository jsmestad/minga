defmodule MingaEditor.State.Windows do
  @moduledoc """
  Groups window-related fields from EditorState.

  Tracks the window tree layout, the map of window structs, the active
  window id, and the next available window id for splits.
  """

  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @type t(window) :: %__MODULE__{
          tree: WindowTree.t() | nil,
          map: %{Window.id() => window},
          active: Window.id(),
          next_id: Window.id()
        }

  @type t :: t(Window.t())

  defstruct tree: nil,
            map: %{},
            active: 1,
            next_id: 2

  @doc "Builds an exact window container from explicit owner fields."
  @spec new(WindowTree.t() | nil, Window.id(), Window.id(), %{Window.id() => window}) :: t(window)
        when window: term()
  def new(tree, active, next_id, map) when is_map(map) do
    %__MODULE__{tree: tree, active: active, next_id: next_id, map: map}
  end

  @doc "Returns the active window struct, or nil if no windows are initialized."
  @spec active_struct(t(window)) :: window | nil when window: term()
  def active_struct(%__MODULE__{map: windows, active: id}) do
    Map.get(windows, id)
  end

  @doc "Returns true if the window tree contains a split."
  @spec split?(t(window)) :: boolean() when window: term()
  def split?(%__MODULE__{tree: nil}), do: false
  def split?(%__MODULE__{tree: {:leaf, _}}), do: false
  def split?(%__MODULE__{tree: {:split, _, _, _, _}}), do: true

  @doc "Replaces the window layout tree."
  @spec set_tree(t(window), WindowTree.t() | nil) :: t(window) when window: term()
  def set_tree(%__MODULE__{} = windows, tree) do
    %{windows | tree: tree}
  end

  @doc "Sets the active window id."
  @spec set_active(t(window), Window.id()) :: t(window) when window: term()
  def set_active(%__MODULE__{} = windows, id), do: %{windows | active: id}

  @doc "Replaces the window map."
  @spec set_map(t(window), %{Window.id() => window}) :: t(window) when window: term()
  def set_map(%__MODULE__{} = windows, map) when is_map(map), do: %{windows | map: map}

  @doc "Sets the next available window id."
  @spec set_next_id(t(window), Window.id()) :: t(window) when window: term()
  def set_next_id(%__MODULE__{} = windows, id), do: %{windows | next_id: id}

  @doc "Allocates the next window id and advances the allocator."
  @spec allocate_id(t(window)) :: {Window.id(), t(window)} when window: term()
  def allocate_id(%__MODULE__{next_id: id} = windows) do
    {id, set_next_id(windows, id + 1)}
  end

  @doc "Adds a window to the container using the window's id."
  @spec add_window(t(), Window.t()) :: t()
  def add_window(%__MODULE__{map: map} = windows, %Window{id: id} = window) do
    set_map(windows, Map.put(map, id, window))
  end

  @doc "Removes a tree-managed window from the container."
  @spec remove_window(t(window), Window.id()) :: {:ok, t(window)} | :error when window: term()
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
  @spec delete_window(t(window), Window.id()) :: t(window) when window: term()
  def delete_window(%__MODULE__{map: map} = windows, id) do
    set_map(windows, Map.delete(map, id))
  end

  @doc "Fetches a window by id."
  @spec fetch(t(window), Window.id()) :: {:ok, window} | :error when window: term()
  def fetch(%__MODULE__{map: map}, id), do: Map.fetch(map, id)

  @doc "Replaces one window with a concrete owner-produced value."
  @spec replace_window(t(), Window.id(), Window.t()) :: t()
  def replace_window(%__MODULE__{map: windows} = state, id, %Window{} = window) do
    if Map.has_key?(windows, id) do
      set_map(state, Map.put(windows, id, window))
    else
      state
    end
  end

  @doc "Replaces every window showing a buffer with concrete owner-produced values."
  @spec replace_buffer_windows(t(), pid(), %{Window.id() => Window.t()}) :: t()
  def replace_buffer_windows(%__MODULE__{map: windows} = state, buffer, replacements)
      when is_pid(buffer) and is_map(replacements) do
    map =
      Enum.reduce(windows, windows, fn
        {id, %Window{content: {:buffer, ^buffer}}}, acc ->
          case Map.fetch(replacements, id) do
            {:ok, %Window{} = window} -> Map.put(acc, id, window)
            :error -> acc
          end

        _entry, acc ->
          acc
      end)

    set_map(state, map)
  end

  @doc "Sets a window's pinned state."
  @spec set_pinned(t(), Window.id(), boolean()) :: t()
  def set_pinned(%__MODULE__{} = state, id, pinned?) when is_boolean(pinned?) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.set_pinned(window, pinned?))
      :error -> state
    end
  end

  @doc "Resizes one window."
  @spec resize(t(), Window.id(), non_neg_integer(), non_neg_integer()) :: t()
  def resize(%__MODULE__{} = state, id, rows, cols) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.resize(window, rows, cols))
      :error -> state
    end
  end

  @doc "Sets one window's viewport."
  @spec set_viewport(t(), Window.id(), MingaEditor.Viewport.t()) :: t()
  def set_viewport(%__MODULE__{} = state, id, viewport) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.set_viewport(window, viewport))
      :error -> state
    end
  end

  @doc "Sets one window's cursor."
  @spec set_cursor(t(), Window.id(), {non_neg_integer(), non_neg_integer()}) :: t()
  def set_cursor(%__MODULE__{} = state, id, cursor) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.set_cursor(window, cursor))
      :error -> state
    end
  end

  @doc "Scrolls one window horizontally."
  @spec scroll_horizontal(t(), Window.id(), integer()) :: t()
  def scroll_horizontal(%__MODULE__{} = state, id, delta) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.scroll_horizontal(window, delta))
      :error -> state
    end
  end

  @doc "Replaces fold ranges in one window."
  @spec set_fold_ranges(t(), Window.id(), list()) :: t()
  def set_fold_ranges(%__MODULE__{} = state, id, ranges) when is_list(ranges) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.set_fold_ranges(window, ranges))
      :error -> state
    end
  end

  @doc "Replaces text-object positions in one window."
  @spec set_textobject_positions(t(), Window.id(), map()) :: t()
  def set_textobject_positions(%__MODULE__{} = state, id, positions) when is_map(positions) do
    case fetch(state, id) do
      {:ok, window} ->
        replace_window(state, id, Window.set_textobject_positions(window, positions))

      :error ->
        state
    end
  end

  @doc "Updates one window's fold state."
  @spec toggle_fold(t(), Window.id(), non_neg_integer()) :: t()
  def toggle_fold(%__MODULE__{} = state, id, line) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.toggle_fold(window, line))
      :error -> state
    end
  end

  @spec fold_at(t(), Window.id(), non_neg_integer()) :: t()
  def fold_at(%__MODULE__{} = state, id, line) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.fold_at(window, line))
      :error -> state
    end
  end

  @spec unfold_at(t(), Window.id(), non_neg_integer()) :: t()
  def unfold_at(%__MODULE__{} = state, id, line) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.unfold_at(window, line))
      :error -> state
    end
  end

  @spec fold_recursive_at(t(), Window.id(), non_neg_integer()) :: t()
  def fold_recursive_at(%__MODULE__{} = state, id, line) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.fold_recursive_at(window, line))
      :error -> state
    end
  end

  @spec unfold_recursive_at(t(), Window.id(), non_neg_integer()) :: t()
  def unfold_recursive_at(%__MODULE__{} = state, id, line) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.unfold_recursive_at(window, line))
      :error -> state
    end
  end

  @spec fold_all(t(), Window.id()) :: t()
  def fold_all(%__MODULE__{} = state, id) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.fold_all(window))
      :error -> state
    end
  end

  @spec unfold_all(t(), Window.id()) :: t()
  def unfold_all(%__MODULE__{} = state, id) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.unfold_all(window))
      :error -> state
    end
  end

  @spec unfold_containing(t(), Window.id(), [non_neg_integer()]) :: t()
  def unfold_containing(%__MODULE__{} = state, id, lines) do
    case fetch(state, id) do
      {:ok, window} -> replace_window(state, id, Window.unfold_containing(window, lines))
      :error -> state
    end
  end

  @doc "Sets document symbols in every window showing a buffer."
  @spec set_document_symbols_for_buffer(t(), pid(), list()) :: t()
  def set_document_symbols_for_buffer(%__MODULE__{} = state, buffer, symbols)
      when is_pid(buffer) and is_list(symbols) do
    replacements =
      Map.new(state.map, fn
        {id, %Window{content: {:buffer, ^buffer}} = window} ->
          {id, Window.set_document_symbols(window, symbols)}

        {id, window} ->
          {id, window}
      end)

    replace_buffer_windows(state, buffer, replacements)
  end

  @doc "Finds the first window showing a buffer."
  @spec find_by_buffer(t(), pid()) :: {Window.id(), Window.t()} | nil
  def find_by_buffer(%__MODULE__{map: map}, buffer) when is_pid(buffer) do
    Enum.find(map, fn
      {_id, %Window{content: {:buffer, ^buffer}}} -> true
      _entry -> false
    end)
  end

  @doc "Finds the first agent chat window."
  @spec find_agent_chat(t()) :: {Window.id(), Window.t()} | nil
  def find_agent_chat(%__MODULE__{map: map}) do
    Enum.find(map, fn
      {_id, %Window{content: {:agent_chat, _}}} -> true
      _entry -> false
    end)
  end

  @doc "Finds the first buffer window."
  @spec find_buffer_window(t()) :: {Window.id(), Window.t()} | nil
  def find_buffer_window(%__MODULE__{map: map}) do
    Enum.find(map, fn
      {_id, %Window{content: {:buffer, _}}} -> true
      _entry -> false
    end)
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
