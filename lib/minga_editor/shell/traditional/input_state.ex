defmodule MingaEditor.Shell.Traditional.InputState do
  @moduledoc """
  Pure aggregate for Traditional renderer-authored hit regions and TUI leader input.
  """

  alias MingaEditor.Shell.Traditional.ClickRegions
  alias MingaEditor.Shell.Traditional.SpaceLeader

  @type t :: %__MODULE__{click_regions: ClickRegions.t(), space_leader: SpaceLeader.t()}

  defstruct click_regions: %ClickRegions{}, space_leader: %SpaceLeader{}

  @doc "Returns the renderer-authored click-region value."
  @spec click_regions(t()) :: ClickRegions.t()
  def click_regions(%__MODULE__{click_regions: regions}), do: regions

  @doc "Installs click regions from one correlated render."
  @spec install_click_regions(
          t(),
          [MingaEditor.Shell.Traditional.Modeline.click_region()],
          [ClickRegions.tab_bar_region()]
        ) :: t()
  def install_click_regions(%__MODULE__{} = input, modeline, tab_bar) do
    %{input | click_regions: ClickRegions.install(input.click_regions, modeline, tab_bar)}
  end

  @doc "Installs one already-correlated click-region value."
  @spec install_click_regions(t(), ClickRegions.t()) :: t()
  def install_click_regions(%__MODULE__{} = input, %ClickRegions{} = regions),
    do: %{input | click_regions: regions}

  @doc "Returns the modeline command under a rendered column."
  @spec modeline_command_at(t(), non_neg_integer()) :: atom() | nil
  def modeline_command_at(%__MODULE__{click_regions: regions}, col),
    do: ClickRegions.modeline_command_at(regions, col)

  @doc "Returns the tab-bar command under a rendered cell."
  @spec tab_bar_command_at(t(), non_neg_integer(), non_neg_integer()) ::
          ClickRegions.tab_bar_command() | nil
  def tab_bar_command_at(%__MODULE__{click_regions: regions}, row, col),
    do: ClickRegions.tab_bar_command_at(regions, row, col)

  @doc "Resets renderer-authored hit regions."
  @spec reset_click_regions(t()) :: t()
  def reset_click_regions(%__MODULE__{} = input),
    do: %{input | click_regions: ClickRegions.reset(input.click_regions)}

  @doc "Begins a new space-leader timeout generation."
  @spec begin_space_leader(t()) :: {SpaceLeader.generation(), t()}
  def begin_space_leader(%__MODULE__{} = input) do
    {generation, leader} = SpaceLeader.begin(input.space_leader)
    {generation, %{input | space_leader: leader}}
  end

  @doc "Records the current space-leader timer handle."
  @spec install_space_leader_timer(t(), SpaceLeader.generation(), reference()) :: t()
  def install_space_leader_timer(%__MODULE__{} = input, generation, timer) do
    %{input | space_leader: SpaceLeader.install_timer(input.space_leader, generation, timer)}
  end

  @doc "Expires only a matching space-leader generation."
  @spec expire_space_leader(t(), SpaceLeader.generation()) :: {:expired | :stale, t()}
  def expire_space_leader(%__MODULE__{} = input, generation) do
    case SpaceLeader.expire(input.space_leader, generation) do
      {result, leader} -> {result, %{input | space_leader: leader}}
    end
  end

  @doc "Returns whether a space-leader window is pending."
  @spec space_leader_pending?(t()) :: boolean()
  def space_leader_pending?(%__MODULE__{space_leader: leader}), do: SpaceLeader.pending?(leader)

  @doc "Returns the current space-leader timer handle."
  @spec space_leader_timer(t()) :: reference() | nil
  def space_leader_timer(%__MODULE__{space_leader: leader}), do: SpaceLeader.timer(leader)

  @doc "Resets the current space-leader window."
  @spec reset_space_leader(t()) :: t()
  def reset_space_leader(%__MODULE__{} = input),
    do: %{input | space_leader: SpaceLeader.reset(input.space_leader)}
end
