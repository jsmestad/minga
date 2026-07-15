defmodule MingaEditor.Renderer.ReceiptProjection do
  @moduledoc """
  Pure projection of an accepted renderer receipt onto Editor-owned values.

  Correlation and shell-identity acceptance stay at the root transition. This
  module projects only the already-accepted layout, focus, click-region, and
  window observations through their focused value owners.
  """

  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Renderer.WindowObservation
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Identity
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.ClickRegions
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Render
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.Viewport

  @typedoc "Projected root values produced by one accepted receipt."
  @type result :: {SessionState.t(), Runtime.t(), Render.t()}

  @doc "Projects one accepted receipt through workspace, shell, and render owners."
  @spec project(
          SessionState.t(),
          Runtime.t(),
          Render.t(),
          RenderReceipt.t(),
          RenderCorrelation.t()
        ) :: result()
  def project(workspace, runtime, render, %RenderReceipt{} = receipt, correlation) do
    workspace = observe_windows(workspace, receipt.window_observations)
    runtime = accept_click_regions(runtime, receipt)

    render =
      render
      |> Render.accept_correlation(correlation)
      |> Render.cache_layout(receipt.layout, receipt.focus_tree)

    {workspace, runtime, render}
  end

  @spec observe_windows(SessionState.t(), map()) :: SessionState.t()
  defp observe_windows(%SessionState{} = workspace, observations) do
    Enum.reduce(observations, workspace, fn
      {id,
       %WindowObservation{
         buffer: buffer,
         buffer_version: version,
         viewport: %Viewport{} = viewport
       }},
      acc ->
        SessionState.observe_window(acc, id, buffer, viewport, version)
    end)
  end

  @spec accept_click_regions(Runtime.t(), RenderReceipt.t()) :: Runtime.t()
  defp accept_click_regions(
         %Runtime{} = runtime,
         %RenderReceipt{
           shell_id: shell_id,
           shell_identity: %Identity{} = identity,
           click_regions: %ClickRegions{} = regions
         }
       ) do
    if shell_id == Runtime.id(runtime) and Runtime.matches_identity?(runtime, identity) do
      shell_state =
        runtime
        |> Runtime.state()
        |> TraditionalState.install_click_regions(regions)

      Runtime.install_traditional_state(runtime, shell_state)
    else
      runtime
    end
  end

  defp accept_click_regions(%Runtime{} = runtime, %RenderReceipt{}), do: runtime
end
