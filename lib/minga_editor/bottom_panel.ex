defmodule MingaEditor.BottomPanel do
  @moduledoc """
  State for the bottom panel container.

  The bottom panel is a resizable, tabbed container below the editor surface
  (above the status bar) in GUI frontends. It hosts Messages, Diagnostics,
  Terminal, and future panel tabs. The BEAM sends declarative state each
  frame; frontends render it with their native toolkit.

  ## Tab types

  - `:messages` - editor log messages (always present)
  - `:diagnostics` - LSP diagnostics (future)
  - `:terminal` - integrated terminal (future)

  ## Visibility state machine

  The panel opens only through explicit user actions. Logging a warning or error never changes its visibility or focus.

  - `visible` tracks whether the panel is shown.
  - `dismissed` records an explicit dismissal until the next explicit open.
  - `filter` records an optional user-selected preset, including `:warnings` for the View Warnings command.
  """

  @type tab :: :messages | :diagnostics | :terminal

  @type filter_preset :: :warnings | nil

  @type t :: %__MODULE__{
          visible: boolean(),
          focused: boolean(),
          active_tab: tab(),
          tabs: [tab()],
          dismissed: boolean(),
          filter: filter_preset(),
          height_percent: non_neg_integer()
        }

  defstruct visible: false,
            focused: false,
            active_tab: :messages,
            tabs: [:messages],
            dismissed: false,
            filter: nil,
            height_percent: 30

  @doc "Toggle panel visibility. Clears dismissed state on explicit open."
  @spec toggle(t()) :: t()
  def toggle(%__MODULE__{visible: true} = panel) do
    %{panel | visible: false, focused: false}
  end

  def toggle(%__MODULE__{visible: false} = panel) do
    %{panel | visible: true, dismissed: false, filter: nil}
  end

  @doc "Show the panel on a specific tab with an optional filter preset."
  @spec show(t(), tab(), filter_preset()) :: t()
  def show(%__MODULE__{} = panel, tab \\ :messages, filter \\ nil) do
    %{panel | visible: true, active_tab: tab, filter: filter, dismissed: false}
  end

  @doc "Hide the panel."
  @spec hide(t()) :: t()
  def hide(%__MODULE__{} = panel) do
    %{panel | visible: false, focused: false}
  end

  @doc "Dismiss the panel (prevents auto-open until explicit open)."
  @spec dismiss(t()) :: t()
  def dismiss(%__MODULE__{} = panel) do
    %{panel | visible: false, focused: false, dismissed: true}
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

  @doc "Switch to a tab by index."
  @spec switch_tab(t(), non_neg_integer()) :: t()
  def switch_tab(%__MODULE__{tabs: tabs} = panel, index)
      when is_integer(index) and index >= 0 do
    case Enum.at(tabs, index) do
      nil -> panel
      tab -> %{panel | active_tab: tab, filter: nil}
    end
  end

  @doc "Cycle to the next tab."
  @spec next_tab(t()) :: t()
  def next_tab(%__MODULE__{tabs: tabs, active_tab: current} = panel) do
    current_index = Enum.find_index(tabs, &(&1 == current)) || 0
    next_index = rem(current_index + 1, Enum.count(tabs))
    %{panel | active_tab: Enum.at(tabs, next_index), filter: nil}
  end

  @doc "Cycle to the previous tab."
  @spec prev_tab(t()) :: t()
  def prev_tab(%__MODULE__{tabs: tabs, active_tab: current} = panel) do
    current_index = Enum.find_index(tabs, &(&1 == current)) || 0
    prev_index = rem(current_index - 1 + Enum.count(tabs), Enum.count(tabs))
    %{panel | active_tab: Enum.at(tabs, prev_index), filter: nil}
  end

  @doc "Update panel height (clamped to 10-60%)."
  @spec resize(t(), non_neg_integer()) :: t()
  def resize(%__MODULE__{} = panel, height_percent)
      when is_integer(height_percent) do
    clamped = max(10, min(60, height_percent))
    %{panel | height_percent: clamped}
  end

  @doc "Tab type byte for protocol encoding."
  @spec tab_type_byte(tab()) :: non_neg_integer()
  def tab_type_byte(:messages), do: 0x01
  def tab_type_byte(:diagnostics), do: 0x02
  def tab_type_byte(:terminal), do: 0x03

  @doc "Tab display name for protocol encoding."
  @spec tab_name(tab()) :: String.t()
  def tab_name(:messages), do: "Messages"
  def tab_name(:diagnostics), do: "Diagnostics"
  def tab_name(:terminal), do: "Terminal"

  @doc "Filter preset byte for protocol encoding."
  @spec filter_byte(filter_preset()) :: non_neg_integer()
  def filter_byte(nil), do: 0x00
  def filter_byte(:warnings), do: 0x01
end
