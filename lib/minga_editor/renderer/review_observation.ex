defmodule MingaEditor.Renderer.ReviewObservation do
  @moduledoc "Version-bound geometry for one successfully rendered read-only review window."

  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Renderer.RenderWindow
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Viewport

  @enforce_keys [:accessibility_generation, :scope, :source, :viewport, :total_rows]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          accessibility_generation: pos_integer(),
          scope: Runtime.review_scope(),
          source: Preview.review_source(),
          viewport: Viewport.t(),
          total_rows: non_neg_integer()
        }

  @doc "Captures rendered source evidence, never merely a retained projection cache."
  @spec from_window(RenderWindow.t()) :: t() | nil
  def from_window(
        %RenderWindow{
          content: {:agent_review, :semantic},
          review_frame_rendered?: true,
          viewport: %Viewport{} = viewport
        } = window
      ) do
    {scope, source, total_rows} = RenderWindow.review_observation_source(window)

    %__MODULE__{
      accessibility_generation: window.accessibility_generation,
      scope: scope,
      source: source,
      viewport: viewport,
      total_rows: total_rows
    }
  end

  def from_window(%RenderWindow{}), do: nil
end
