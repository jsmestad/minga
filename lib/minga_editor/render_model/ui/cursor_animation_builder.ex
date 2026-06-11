defmodule MingaEditor.RenderModel.UI.CursorAnimationBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.CursorAnimation

  @doc """
  Builds the cursor-animation semantic model from the configured preference.

  Returns nil when the frontend is not a GUI; cursor animation only applies to
  native GUI frontends.
  """
  @spec build(boolean() | nil, boolean()) :: CursorAnimation.t() | nil
  def build(_enabled?, false), do: nil
  def build(enabled?, true) when is_boolean(enabled?), do: %CursorAnimation{enabled?: enabled?}
  def build(nil, true), do: %CursorAnimation{enabled?: true}
end
