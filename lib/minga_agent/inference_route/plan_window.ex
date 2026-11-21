defmodule MingaAgent.InferenceRoute.PlanWindow do
  @moduledoc """
  One subscription limit window a route reports, such as a 5-hour or weekly limit.

  `utilization` is the used fraction from 0 to 1. `resets_at` is when the window resets, or nil when the route does not know. `status` is the route's own verdict: `:allowed`, `:warning` as the limit approaches, or `:rejected` once requests are refused.
  """

  @enforce_keys [:kind, :utilization, :resets_at, :status]
  defstruct @enforce_keys

  @type status :: :allowed | :warning | :rejected

  @type t :: %__MODULE__{
          kind: String.t(),
          utilization: float(),
          resets_at: DateTime.t() | nil,
          status: status()
        }

  @type error :: {:invalid_plan_window, atom()}

  @known_kinds %{"five_hour" => "5h", "seven_day" => "7d", "one_day" => "1d"}

  @doc "Builds a validated window. Integer utilization is accepted and stored as a float."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, error()}
  def new(%__MODULE__{} = window), do: window |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: attrs |> Map.new() |> new(), else: new(:invalid)
  end

  def new(attrs) when is_map(attrs) do
    with {:ok, kind} <- kind(Map.get(attrs, :kind)),
         {:ok, utilization} <- utilization(Map.get(attrs, :utilization)),
         {:ok, resets_at} <- resets_at(Map.get(attrs, :resets_at)),
         {:ok, status} <- status(Map.get(attrs, :status)) do
      {:ok,
       %__MODULE__{kind: kind, utilization: utilization, resets_at: resets_at, status: status}}
    end
  end

  def new(_attrs), do: {:error, {:invalid_plan_window, :attrs}}

  @doc "Validates a reported window list. An empty list means the route has no usage data."
  @spec new_list(term()) :: {:ok, [t()] | nil} | {:error, error()}
  def new_list(nil), do: {:ok, nil}
  def new_list([]), do: {:ok, nil}

  def new_list(windows) when is_list(windows) do
    windows
    |> Enum.reduce_while({:ok, []}, fn window, {:ok, acc} ->
      case new(window) do
        {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.reverse(valid)}
      error -> error
    end
  end

  def new_list(_windows), do: {:error, {:invalid_plan_window, :list}}

  @doc "Returns the most used window, or nil when there is no usage data."
  @spec busiest([t()] | nil) :: t() | nil
  def busiest(nil), do: nil
  def busiest([]), do: nil
  def busiest(windows) when is_list(windows), do: Enum.max_by(windows, & &1.utilization)

  @doc "Returns the window that is refusing requests, preferring the one that resets last."
  @spec rejected([t()] | nil) :: t() | nil
  def rejected(windows) when is_list(windows) do
    windows
    |> Enum.filter(&(&1.status == :rejected))
    |> Enum.max_by(&reset_sort_key/1, fn -> nil end)
  end

  def rejected(nil), do: nil

  @doc "Returns a short label for a window kind, such as `5h` for `five_hour`."
  @spec kind_label(String.t()) :: String.t()
  def kind_label(kind) when is_binary(kind), do: Map.get(@known_kinds, kind, kind)

  @doc "Returns the used percentage, rounded down, from 0 to 100."
  @spec percent(t()) :: non_neg_integer()
  def percent(%__MODULE__{utilization: utilization}), do: trunc(utilization * 100)

  @typedoc "Converts a UTC `DateTime` to the local calendar date and time the user reads."
  @type to_local :: (DateTime.t() -> :calendar.datetime())

  @doc """
  Formats when a window resets as a local clock time, such as `3:40 PM`, with the weekday when the reset is not on the same local day as `now`. Returns nil when the reset time is unknown. The caller supplies `now` and the local-time conversion, so this value never reads the clock.
  """
  @spec reset_label(t(), DateTime.t(), to_local()) :: String.t() | nil
  def reset_label(%__MODULE__{resets_at: nil}, _now, _to_local), do: nil

  def reset_label(%__MODULE__{resets_at: at}, %DateTime{} = now, to_local)
      when is_function(to_local, 1) do
    {reset_date, {hour, minute, _second}} = to_local.(at)
    {today, _time} = to_local.(now)

    time =
      "#{rem(hour + 11, 12) + 1}:#{String.pad_leading(Integer.to_string(minute), 2, "0")} #{meridiem(hour)}"

    if reset_date == today, do: time, else: "#{weekday(reset_date)} #{time}"
  end

  @spec meridiem(0..23) :: String.t()
  defp meridiem(hour) when hour < 12, do: "AM"
  defp meridiem(_hour), do: "PM"

  @spec weekday(:calendar.date()) :: String.t()
  defp weekday(date) do
    Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), :calendar.day_of_the_week(date) - 1)
  end

  @spec reset_sort_key(t()) :: integer()
  defp reset_sort_key(%__MODULE__{resets_at: nil}), do: 0
  defp reset_sort_key(%__MODULE__{resets_at: at}), do: DateTime.to_unix(at)

  @spec kind(term()) :: {:ok, String.t()} | {:error, error()}
  defp kind(kind) when is_binary(kind) and kind != "", do: {:ok, kind}
  defp kind(_kind), do: {:error, {:invalid_plan_window, :kind}}

  @spec utilization(term()) :: {:ok, float()} | {:error, error()}
  defp utilization(value) when is_number(value) and value >= 0 and value <= 1,
    do: {:ok, value / 1}

  defp utilization(_value), do: {:error, {:invalid_plan_window, :utilization}}

  @spec resets_at(term()) :: {:ok, DateTime.t() | nil} | {:error, error()}
  defp resets_at(nil), do: {:ok, nil}
  defp resets_at(%DateTime{} = at), do: {:ok, at}
  defp resets_at(_value), do: {:error, {:invalid_plan_window, :resets_at}}

  @spec status(term()) :: {:ok, status()} | {:error, error()}
  defp status(status) when status in [:allowed, :warning, :rejected], do: {:ok, status}
  defp status(_status), do: {:error, {:invalid_plan_window, :status}}
end
