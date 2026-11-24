defmodule MingaEditor.StatusBar.PlanLimit do
  @moduledoc """
  The near-limit modeline indicator for a subscription model route.

  Minga shows nothing under normal usage and nothing without data. A window at 80% or more shows a quiet `Claude 82% · 5h`; a refusing window shows `Claude limit · resets 3:40 PM`. The text carries the meaning on its own, and `level` only chooses the color. A window whose reset time has passed no longer limits anything, so it is ignored rather than guessed about.
  """

  alias MingaAgent.InferenceRoute.PlanWindow

  @enforce_keys [:level, :text]
  defstruct @enforce_keys

  @type level :: :warning | :rejected
  @type t :: %__MODULE__{level: level(), text: String.t()}

  @threshold_percent 80

  @doc """
  Returns the indicator for a route's reported windows at `now`, or nil when nothing should show. `to_local` converts a reset time to the clock the user reads, as `PlanWindow.reset_label/3` expects, so this function never reads the clock.
  """
  @spec from_usage(String.t(), [PlanWindow.t()] | nil, DateTime.t(), PlanWindow.to_local()) ::
          t() | nil
  def from_usage(_short_name, nil, %DateTime{}, _to_local), do: nil

  def from_usage(short_name, windows, %DateTime{} = now, to_local)
      when is_binary(short_name) and is_list(windows) and is_function(to_local, 1) do
    windows
    |> PlanWindow.in_force(now)
    |> indicator(short_name, now, to_local)
  end

  @spec indicator([PlanWindow.t()], String.t(), DateTime.t(), PlanWindow.to_local()) :: t() | nil
  defp indicator(windows, short_name, now, to_local) do
    case PlanWindow.rejected(windows) do
      %PlanWindow{} = window -> rejected(short_name, window, now, to_local)
      nil -> windows |> PlanWindow.busiest() |> near_limit(short_name)
    end
  end

  @spec rejected(String.t(), PlanWindow.t(), DateTime.t(), PlanWindow.to_local()) :: t()
  defp rejected(short_name, window, now, to_local) do
    text =
      case PlanWindow.reset_label(window, now, to_local) do
        nil -> "#{short_name} limit"
        reset -> "#{short_name} limit · resets #{reset}"
      end

    %__MODULE__{level: :rejected, text: text}
  end

  @spec near_limit(PlanWindow.t() | nil, String.t()) :: t() | nil
  defp near_limit(nil, _short_name), do: nil

  defp near_limit(%PlanWindow{} = window, short_name) do
    percent = PlanWindow.percent(window)

    if percent >= @threshold_percent do
      %__MODULE__{
        level: :warning,
        text: "#{short_name} #{percent}% · #{PlanWindow.kind_label(window.kind)}"
      }
    end
  end
end
