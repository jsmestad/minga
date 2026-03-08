defmodule Minga.Agent.PanelState do
  @moduledoc """
  State for the agent chat panel UI.

  Tracks visibility, scroll position, input text, spinner animation,
  and other UI-only concerns. Stored in `Editor.State` and updated
  by agent event handlers.
  """

  @typedoc "Thinking level for models that support extended reasoning."
  @type thinking_level :: String.t()

  @typedoc "Agent panel UI state."
  @type t :: %__MODULE__{
          visible: boolean(),
          scroll_offset: non_neg_integer(),
          input_text: String.t(),
          spinner_frame: non_neg_integer(),
          provider_name: String.t(),
          model_name: String.t(),
          thinking_level: thinking_level(),
          input_focused: boolean(),
          auto_scroll: boolean()
        }

  @enforce_keys []
  defstruct visible: false,
            scroll_offset: 0,
            input_text: "",
            spinner_frame: 0,
            provider_name: "anthropic",
            model_name: "claude-sonnet-4",
            thinking_level: "medium",
            input_focused: false,
            auto_scroll: true

  @doc "Creates a new panel state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Toggles panel visibility."
  @spec toggle(t()) :: t()
  def toggle(%__MODULE__{} = state) do
    %{state | visible: !state.visible}
  end

  @doc "Advances the spinner animation frame."
  @spec tick_spinner(t()) :: t()
  def tick_spinner(%__MODULE__{} = state) do
    %{state | spinner_frame: state.spinner_frame + 1}
  end

  @doc "Appends a character to the input text."
  @spec insert_char(t(), String.t()) :: t()
  def insert_char(%__MODULE__{} = state, char) do
    %{state | input_text: state.input_text <> char}
  end

  @doc "Deletes the last character from the input text."
  @spec delete_char(t()) :: t()
  def delete_char(%__MODULE__{input_text: ""} = state), do: state

  def delete_char(%__MODULE__{input_text: text} = state) do
    {_, rest} = String.split_at(text, -1)
    _ = rest
    %{state | input_text: String.slice(text, 0..-2//1)}
  end

  @doc "Clears the input text (after submission)."
  @spec clear_input(t()) :: t()
  def clear_input(%__MODULE__{} = state) do
    %{state | input_text: ""}
  end

  @doc "Scrolls the content up by the given number of lines. Disengages auto-scroll."
  @spec scroll_up(t(), non_neg_integer()) :: t()
  def scroll_up(%__MODULE__{} = state, amount) do
    %{state | scroll_offset: max(state.scroll_offset - amount, 0), auto_scroll: false}
  end

  @doc "Scrolls the content down by the given number of lines. Disengages auto-scroll."
  @spec scroll_down(t(), non_neg_integer()) :: t()
  def scroll_down(%__MODULE__{} = state, amount) do
    %{state | scroll_offset: state.scroll_offset + amount, auto_scroll: false}
  end

  @doc "Scrolls to the bottom and re-engages auto-scroll."
  @spec scroll_to_bottom(t()) :: t()
  def scroll_to_bottom(%__MODULE__{} = state) do
    %{state | scroll_offset: 999_999, auto_scroll: true}
  end

  @doc "Scrolls to the top of the chat. Disengages auto-scroll."
  @spec scroll_to_top(t()) :: t()
  def scroll_to_top(%__MODULE__{} = state) do
    %{state | scroll_offset: 0, auto_scroll: false}
  end

  @doc """
  Scrolls to the bottom only if auto-scroll is engaged.

  Called by event handlers when new streaming content arrives. No-ops if the
  user has manually scrolled away from the bottom.
  """
  @spec maybe_auto_scroll(t()) :: t()
  def maybe_auto_scroll(%__MODULE__{auto_scroll: true} = state), do: scroll_to_bottom(state)
  def maybe_auto_scroll(%__MODULE__{} = state), do: state

  @doc "Re-engages auto-scroll (e.g., on new agent turn start)."
  @spec engage_auto_scroll(t()) :: t()
  def engage_auto_scroll(%__MODULE__{} = state) do
    scroll_to_bottom(%{state | auto_scroll: true})
  end

  @doc "Sets the input focus state."
  @spec set_input_focused(t(), boolean()) :: t()
  def set_input_focused(%__MODULE__{} = state, focused) do
    %{state | input_focused: focused}
  end
end
