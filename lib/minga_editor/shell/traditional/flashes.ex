defmodule MingaEditor.Shell.Traditional.Flashes do
  @moduledoc """
  Pure aggregate for independent navigation and yank flash owners.

  Replacing, advancing, or cancelling one leaf never changes the other leaf.
  """

  alias MingaEditor.Shell.Traditional.NavFlash
  alias MingaEditor.Shell.Traditional.YankFlash

  @type t :: %__MODULE__{nav: NavFlash.t(), yank: YankFlash.t()}

  defstruct nav: %NavFlash{}, yank: %YankFlash{}

  @doc "Replaces only the navigation flash."
  @spec replace_nav(t(), non_neg_integer()) :: t()
  def replace_nav(%__MODULE__{} = flashes, line),
    do: %{flashes | nav: NavFlash.replace(flashes.nav, line)}

  @doc "Records only the navigation timer handle."
  @spec record_nav_timer(t(), NavFlash.generation(), reference()) :: t()
  def record_nav_timer(%__MODULE__{} = flashes, generation, timer),
    do: %{flashes | nav: NavFlash.record_timer(flashes.nav, generation, timer)}

  @doc "Advances only the matching navigation generation."
  @spec advance_nav(t(), NavFlash.generation()) :: {:continue | :done | :stale, t()}
  def advance_nav(%__MODULE__{} = flashes, generation) do
    case NavFlash.advance(flashes.nav, generation) do
      {result, nav} -> {result, %{flashes | nav: nav}}
    end
  end

  @doc "Cancels only the navigation flash."
  @spec cancel_nav(t()) :: t()
  def cancel_nav(%__MODULE__{} = flashes), do: %{flashes | nav: NavFlash.cancel(flashes.nav)}

  @doc "Replaces only the yank flash."
  @spec replace_yank(
          t(),
          pid(),
          YankFlash.position(),
          YankFlash.position(),
          YankFlash.range_type()
        ) :: t()
  def replace_yank(%__MODULE__{} = flashes, buf, start_pos, end_pos, range_type) do
    %{flashes | yank: YankFlash.replace(flashes.yank, buf, start_pos, end_pos, range_type)}
  end

  @doc "Records only the yank timer handle."
  @spec record_yank_timer(t(), YankFlash.generation(), reference()) :: t()
  def record_yank_timer(%__MODULE__{} = flashes, generation, timer),
    do: %{flashes | yank: YankFlash.record_timer(flashes.yank, generation, timer)}

  @doc "Advances only the matching yank generation."
  @spec advance_yank(t(), YankFlash.generation()) :: {:continue | :done | :stale, t()}
  def advance_yank(%__MODULE__{} = flashes, generation) do
    case YankFlash.advance(flashes.yank, generation) do
      {result, yank} -> {result, %{flashes | yank: yank}}
    end
  end

  @doc "Cancels only the yank flash."
  @spec cancel_yank(t()) :: t()
  def cancel_yank(%__MODULE__{} = flashes), do: %{flashes | yank: YankFlash.cancel(flashes.yank)}
end
