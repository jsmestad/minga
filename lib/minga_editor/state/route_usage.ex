defmodule MingaEditor.State.RouteUsage do
  @moduledoc """
  The plan usage each contributed model route last reported, as the Editor learned it from `:inference_route_status_changed` events.

  The Editor never asks the route registry during render. It records each event's payload here and reads the active route's entry when it builds the modeline. A route with no usage data has no entry. Routes that reported before the Editor subscribed appear after their next report.
  """

  alias MingaAgent.InferenceRoute.PlanWindow
  alias MingaAgent.InferenceRoute.Status
  alias MingaAgent.InferenceRoute.StatusChangedEvent
  alias MingaEditor.StatusBar.PlanLimit

  @type entry :: %{short_name: String.t(), plan_usage: [PlanWindow.t()]}
  @type t :: %__MODULE__{routes: %{String.t() => entry()}}

  defstruct routes: %{}

  @doc "Records a route's reported status. A status without usage data forgets the route's usage."
  @spec record(t(), StatusChangedEvent.t()) :: t()
  def record(%__MODULE__{} = usage, %StatusChangedEvent{
        route_id: route_id,
        short_name: short_name,
        status: status
      }) do
    case Status.plan_windows(status) do
      nil ->
        %{usage | routes: Map.delete(usage.routes, route_id)}

      windows ->
        entry = %{short_name: short_name, plan_usage: windows}
        %{usage | routes: Map.put(usage.routes, route_id, entry)}
    end
  end

  @doc """
  Returns the modeline indicator for `route_id` at `now`, or nil for no route, no data, or normal usage. `to_local` converts reset times to the user's clock.
  """
  @spec plan_limit(t(), String.t() | nil, DateTime.t(), PlanWindow.to_local()) ::
          PlanLimit.t() | nil
  def plan_limit(%__MODULE__{}, nil, %DateTime{}, _to_local), do: nil

  def plan_limit(%__MODULE__{routes: routes}, route_id, %DateTime{} = now, to_local)
      when is_binary(route_id) do
    case Map.fetch(routes, route_id) do
      {:ok, %{short_name: short_name, plan_usage: windows}} ->
        PlanLimit.from_usage(short_name, windows, now, to_local)

      :error ->
        nil
    end
  end
end
