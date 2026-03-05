defmodule Minga.Terminal do
  @moduledoc """
  Terminal state for the embedded terminal split.

  The actual PTY and VT emulation live in the Zig process. This module
  tracks the Elixir-side state: whether the terminal is open, its
  dimensions, and the shell path.
  """

  @enforce_keys [:shell]
  defstruct [
    :shell,
    open: false,
    focused: false,
    rows: 0,
    cols: 0,
    row_offset: 0,
    col_offset: 0,
    window_id: nil
  ]

  @type t :: %__MODULE__{
          shell: String.t(),
          open: boolean(),
          focused: boolean(),
          rows: non_neg_integer(),
          cols: non_neg_integer(),
          row_offset: non_neg_integer(),
          col_offset: non_neg_integer(),
          window_id: non_neg_integer() | nil
        }

  @doc "Creates a new terminal state with the user's shell."
  @spec new() :: t()
  def new do
    shell = System.get_env("SHELL") || "/bin/sh"
    %__MODULE__{shell: shell}
  end

  @doc "Marks the terminal as open with the given dimensions."
  @spec open(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: t()
  def open(%__MODULE__{} = term, rows, cols, row_offset, col_offset, window_id) do
    %{
      term
      | open: true,
        focused: true,
        rows: rows,
        cols: cols,
        row_offset: row_offset,
        col_offset: col_offset,
        window_id: window_id
    }
  end

  @doc "Marks the terminal as closed."
  @spec close(t()) :: t()
  def close(%__MODULE__{} = term) do
    %{term | open: false, focused: false, window_id: nil}
  end

  @doc "Sets focus state."
  @spec set_focus(t(), boolean()) :: t()
  def set_focus(%__MODULE__{} = term, focused) when is_boolean(focused) do
    %{term | focused: focused}
  end

  @doc "Updates dimensions (e.g. after a window resize)."
  @spec resize(t(), non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          t()
  def resize(%__MODULE__{} = term, rows, cols, row_offset, col_offset) do
    %{term | rows: rows, cols: cols, row_offset: row_offset, col_offset: col_offset}
  end
end
