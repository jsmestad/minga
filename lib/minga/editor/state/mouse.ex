defmodule Minga.Editor.State.Mouse do
  @moduledoc """
  Mouse interaction state: drag tracking, anchor position, and separator resize.
  """

  alias Minga.Editor.WindowTree

  defstruct dragging: false,
            anchor: nil,
            resize_dragging: nil

  @type t :: %__MODULE__{
          dragging: boolean(),
          anchor: {non_neg_integer(), non_neg_integer()} | nil,
          resize_dragging: {WindowTree.direction(), non_neg_integer()} | nil
        }

  @doc "Begins a content drag from the given buffer position."
  @spec start_drag(t(), {non_neg_integer(), non_neg_integer()}) :: t()
  def start_drag(%__MODULE__{} = mouse, anchor) do
    %{mouse | dragging: true, anchor: anchor}
  end

  @doc "Ends an active drag, clearing the anchor."
  @spec stop_drag(t()) :: t()
  def stop_drag(%__MODULE__{} = mouse) do
    %{mouse | dragging: false, anchor: nil}
  end

  @doc "Begins a separator resize drag in the given direction at the given position."
  @spec start_resize(t(), WindowTree.direction(), non_neg_integer()) :: t()
  def start_resize(%__MODULE__{} = mouse, direction, position) do
    %{mouse | resize_dragging: {direction, position}}
  end

  @doc "Updates the separator position during an active resize drag."
  @spec update_resize(t(), WindowTree.direction(), non_neg_integer()) :: t()
  def update_resize(%__MODULE__{} = mouse, direction, new_position) do
    %{mouse | resize_dragging: {direction, new_position}}
  end

  @doc "Ends a separator resize drag."
  @spec stop_resize(t()) :: t()
  def stop_resize(%__MODULE__{} = mouse) do
    %{mouse | resize_dragging: nil}
  end

  @doc "Returns true if a separator resize drag is active."
  @spec resizing?(t()) :: boolean()
  def resizing?(%__MODULE__{resize_dragging: {_, _}}), do: true
  def resizing?(%__MODULE__{}), do: false
end
