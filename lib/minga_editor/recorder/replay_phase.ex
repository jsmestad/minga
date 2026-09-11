defmodule MingaEditor.Recorder.ReplayPhase do
  @moduledoc "Pure nested replay transitions shared by recorder state owners."

  @type t(post_phase) :: post_phase | {:replaying, pos_integer(), post_phase}

  @doc "Begins a replay or increments its nesting depth."
  @spec start(t(post_phase)) :: {:replaying, pos_integer(), post_phase} when post_phase: term()
  def start({:replaying, depth, post_phase}), do: {:replaying, depth + 1, post_phase}
  def start(phase), do: {:replaying, 1, phase}

  @doc "Stops one replay nesting level and restores the prior phase at the outer boundary."
  @spec stop(t(post_phase)) :: t(post_phase) when post_phase: term()
  def stop({:replaying, depth, post_phase}) when depth > 1,
    do: {:replaying, depth - 1, post_phase}

  def stop({:replaying, 1, post_phase}), do: post_phase
  def stop(phase), do: phase

  @doc "Returns whether a replay is active."
  @spec active?(t(post_phase)) :: boolean() when post_phase: term()
  def active?({:replaying, _depth, _post_phase}), do: true
  def active?(_phase), do: false
end
