defmodule MingaEditor.BottomPanel do
  @moduledoc """
  State for the bottom panel container.

  The bottom panel is a resizable Messages container below the editor surface
  (above the status bar) in GUI frontends. The BEAM sends declarative state each
  frame; frontends render it with their native toolkit.
  ## Visibility state machine

  The panel opens only through explicit user actions. Logging a warning or error never changes its visibility or focus.

  - `visible` tracks whether the panel is shown.
  - `filter` records an optional user-selected preset, including `:warnings` for the View Warnings command.
  """

  @type filter_preset :: :warnings | nil

  @type t :: %__MODULE__{
          visible: boolean(),
          focused: boolean(),
          filter: filter_preset(),
          height_percent: non_neg_integer()
        }

  defstruct visible: false,
            focused: false,
            filter: nil,
            height_percent: 30

  @doc "Toggle panel visibility. Clears filters on explicit open."
  @spec toggle(t()) :: t()
  def toggle(%__MODULE__{visible: true} = panel) do
    %{panel | visible: false, focused: false}
  end

  def toggle(%__MODULE__{visible: false} = panel) do
    %{panel | visible: true, filter: nil}
  end

  @doc "Show the Messages panel with an optional filter preset."
  @spec show(t(), filter_preset()) :: t()
  def show(%__MODULE__{} = panel, filter \\ nil) do
    %{panel | visible: true, filter: filter}
  end

  @doc "Hide the panel."
  @spec hide(t()) :: t()
  def hide(%__MODULE__{} = panel) do
    %{panel | visible: false, focused: false}
  end

  @doc "Focuses the visible panel. Hidden panels stay unfocused."
  @spec focus(t()) :: t()
  def focus(%__MODULE__{visible: true} = panel), do: %{panel | focused: true}
  def focus(%__MODULE__{} = panel), do: %{panel | focused: false}

  @doc "Clears panel focus without changing visibility."
  @spec blur(t()) :: t()
  def blur(%__MODULE__{} = panel), do: %{panel | focused: false}

  @doc "Returns true when the panel is visible and focused."
  @spec focused?(t()) :: boolean()
  def focused?(%__MODULE__{visible: true, focused: true}), do: true
  def focused?(%__MODULE__{}), do: false

  @doc "Update panel height (clamped to 10-60%)."
  @spec resize(t(), non_neg_integer()) :: t()
  def resize(%__MODULE__{} = panel, height_percent)
      when is_integer(height_percent) do
    clamped = max(10, min(60, height_percent))
    %{panel | height_percent: clamped}
  end

  @doc "Filter preset byte for protocol encoding."
  @spec filter_byte(filter_preset()) :: non_neg_integer()
  def filter_byte(nil), do: 0x00
  def filter_byte(:warnings), do: 0x01
end
