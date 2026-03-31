defmodule MingaEditor.State.Picker do
  @moduledoc """
  Groups picker-related fields from EditorState.

  Tracks the current picker instance, the source module providing candidates,
  the buffer index to restore on cancel, and the action-menu overlay state.
  """

  @typedoc "Action menu state: `{actions, selected_index}` or nil when closed."
  @type action_menu ::
          {[MingaEditor.UI.Picker.Source.action_entry()], non_neg_integer()} | nil

  @type t :: %__MODULE__{
          picker: MingaEditor.UI.Picker.t() | nil,
          source: module() | nil,
          restore: non_neg_integer() | nil,
          restore_theme: MingaEditor.UI.Theme.t() | nil,
          action_menu: action_menu(),
          context: map() | nil,
          layout: MingaEditor.UI.Picker.Source.layout(),
          original_source: module() | nil,
          mode_prefix: String.t()
        }

  defstruct picker: nil,
            source: nil,
            restore: nil,
            restore_theme: nil,
            action_menu: nil,
            context: nil,
            layout: :bottom,
            original_source: nil,
            mode_prefix: ""

  @doc "Returns true if a picker is currently open."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{picker: nil}), do: false
  def open?(%__MODULE__{}), do: true

  @doc "Updates the inner `MingaEditor.UI.Picker` instance."
  @spec update_picker(t(), MingaEditor.UI.Picker.t()) :: t()
  def update_picker(%__MODULE__{} = ps, picker) do
    %{ps | picker: picker}
  end
end
