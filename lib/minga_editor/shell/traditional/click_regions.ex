defmodule MingaEditor.Shell.Traditional.ClickRegions do
  @moduledoc """
  Pure owner of renderer-installed Traditional click regions.

  Both region sets come from one correlated render receipt and are installed or
  reset together, preventing mouse hit testing from combining different frames.
  """

  alias MingaEditor.Shell.Traditional.Modeline

  @type tab_bar_command ::
          atom() | {:workspace_goto, non_neg_integer()} | {:tab_goto_id, pos_integer()}
  @type tab_bar_region ::
          {col_start :: non_neg_integer(), col_end :: non_neg_integer(),
           command :: tab_bar_command()}
          | {row :: non_neg_integer(), col_start :: non_neg_integer(),
             col_end :: non_neg_integer(), command :: tab_bar_command()}

  @type t :: %__MODULE__{
          modeline: [Modeline.click_region()],
          tab_bar: [tab_bar_region()]
        }

  defstruct modeline: [], tab_bar: []

  @doc "Installs both region sets from one render observation."
  @spec install(t(), [Modeline.click_region()], [tab_bar_region()]) :: t()
  def install(%__MODULE__{} = regions, modeline, tab_bar)
      when is_list(modeline) and is_list(tab_bar),
      do: %{regions | modeline: modeline, tab_bar: tab_bar}

  @doc "Returns the modeline command under a rendered column."
  @spec modeline_command_at(t(), non_neg_integer()) :: atom() | nil
  def modeline_command_at(%__MODULE__{modeline: regions}, col) do
    case Enum.find(regions, fn {col_start, col_end, _command} ->
           col >= col_start and col < col_end
         end) do
      {_col_start, _col_end, command} -> command
      nil -> nil
    end
  end

  @doc "Returns the tab-bar command under a rendered cell."
  @spec tab_bar_command_at(t(), non_neg_integer(), non_neg_integer()) ::
          tab_bar_command() | nil
  def tab_bar_command_at(%__MODULE__{tab_bar: regions}, row, col) do
    case Enum.find(regions, &tab_bar_region_hit?(&1, row, col)) do
      {_col_start, _col_end, command} -> command
      {_region_row, _col_start, _col_end, command} -> command
      nil -> nil
    end
  end

  @doc "Clears all regions when their render identity is no longer active."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = regions), do: %{regions | modeline: [], tab_bar: []}

  @spec tab_bar_region_hit?(tab_bar_region(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp tab_bar_region_hit?({col_start, col_end, _command}, _row, col),
    do: col >= col_start and col <= col_end

  defp tab_bar_region_hit?({region_row, col_start, col_end, _command}, row, col),
    do: row == region_row and col >= col_start and col <= col_end
end
