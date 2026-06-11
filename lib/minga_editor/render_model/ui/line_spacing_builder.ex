defmodule MingaEditor.RenderModel.UI.LineSpacingBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.LineSpacing

  @doc """
  Builds the line-spacing semantic model from the configured multiplier.

  Returns nil when the frontend is not a GUI (the multiplier is only meaningful
  to native GUI frontends), so the model is omitted from the frame entirely.
  """
  @spec build(number() | nil, boolean()) :: LineSpacing.t() | nil
  def build(_multiplier, false), do: nil
  def build(nil, true), do: %LineSpacing{multiplier: 1.0}

  def build(multiplier, true) when is_number(multiplier) do
    %LineSpacing{multiplier: max(multiplier, 1.0)}
  end
end
