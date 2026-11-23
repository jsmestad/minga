defmodule MingaAgent.UsageLimit do
  @moduledoc """
  A subscription plan's usage limit that refused a request, such as a ChatGPT Pro weekly limit.

  A usage limit is not a transient rate limit: it lasts until its window resets, which can be days away, so Minga never retries a request against it. `service` names the subscription the user recognizes ("ChatGPT", "Claude"). `plan` is the provider's plan type ("pro"), `window_minutes` is the limit window's length, and `resets_at` is when the window resets. Each is nil when the provider did not say; Minga never guesses a reset time.

  This value never reads the clock. Callers pass the time the response was observed and the current time.

  ## Provider signals

    * ChatGPT subscription (`openai_codex`): HTTP 429 with a JSON error body whose `type` (ReqLLM's `provider_code`) is `"usage_limit_reached"`, carrying `plan_type`, `limit_window_minutes`, `resets_at` (Unix seconds), and `resets_in_seconds`. A transient rate limit on the same route has another type.
    * Anthropic API (`anthropic`): HTTP 429 with `error.type` `"rate_limit_error"` and a `retry-after` header. API keys have no subscription usage limit, so every Anthropic 429 stays a transient rate limit.
    * Claude subscription bridge (contributed route): the route reports a `:rejected` plan window with its reset time through `report_usage/3`, and classifies the failed turn as `:rate_limited`. Minga reads the rejected window as the usage limit.
  """

  alias MingaAgent.InferenceRoute.PlanWindow

  @enforce_keys [:service]
  defstruct [:service, plan: nil, window_minutes: nil, resets_at: nil]

  @type t :: %__MODULE__{
          service: String.t(),
          plan: String.t() | nil,
          window_minutes: pos_integer() | nil,
          resets_at: DateTime.t() | nil
        }

  @signal "usage_limit_reached"

  @window_minutes %{"five_hour" => 300, "one_day" => 1_440, "seven_day" => 10_080}
  @window_kinds Map.new(@window_minutes, fn {kind, minutes} -> {minutes, kind} end)

  @doc "Returns a usage limit whose plan, window, and reset the provider did not report."
  @spec unknown(String.t()) :: t()
  def unknown(service) when is_binary(service), do: %__MODULE__{service: service}

  @doc """
  Returns true when an HTTP failure reports a usage limit rather than a transient rate limit.

  Only a 429 whose `provider_code`, or whose error body's `type` or `code`, is `"usage_limit_reached"` reports one. The body may be the error object or wrap it under `"error"`.
  """
  @spec reported?(term(), term(), term()) :: boolean()
  def reported?(429, provider_code, body) do
    error = error_object(body)
    signal?(provider_code) or signal?(field(error, "type")) or signal?(field(error, "code"))
  end

  def reported?(_status, _provider_code, _body), do: false

  @doc """
  Reads a provider's HTTP failure as a usage limit, or returns `:none` when `reported?/3` is false.

  `resets_at` comes from the body's `resets_at`, or from `resets_in_seconds` after `observed_at` when `resets_at` is missing or invalid. A plan, window, or reset that is missing or malformed stays nil.
  """
  @spec from_response(String.t(), term(), term(), term(), DateTime.t()) :: {:ok, t()} | :none
  def from_response(service, status, provider_code, body, %DateTime{} = observed_at)
      when is_binary(service) do
    if reported?(status, provider_code, body) do
      error = error_object(body)

      {:ok,
       %__MODULE__{
         service: service,
         plan: plan(field(error, "plan_type")),
         window_minutes: positive_integer(field(error, "limit_window_minutes")),
         resets_at: resets_at(error, observed_at)
       }}
    else
      :none
    end
  end

  @doc "Returns true when a provider message names a usage limit, for clients that only report text."
  @spec message_signal?(String.t()) :: boolean()
  def message_signal?(message) when is_binary(message), do: String.contains?(message, @signal)

  @doc "Reads a route's refusing plan window as a usage limit."
  @spec from_plan_window(String.t(), PlanWindow.t()) :: t()
  def from_plan_window(service, %PlanWindow{kind: kind, resets_at: resets_at})
      when is_binary(service) do
    %__MODULE__{
      service: service,
      window_minutes: Map.get(@window_minutes, kind),
      resets_at: resets_at
    }
  end

  @doc "Returns the limit as a refusing plan window, so plan usage displays can show it."
  @spec plan_window(t()) :: PlanWindow.t()
  def plan_window(%__MODULE__{window_minutes: minutes, resets_at: resets_at}) do
    %PlanWindow{
      kind: window_kind(minutes),
      utilization: 1.0,
      resets_at: resets_at,
      status: :rejected
    }
  end

  @doc "Returns true until the limit's reset time passes. A limit without a reset time stays in force."
  @spec in_force?(t(), DateTime.t()) :: boolean()
  def in_force?(%__MODULE__{resets_at: nil}, %DateTime{}), do: true

  def in_force?(%__MODULE__{resets_at: resets_at}, %DateTime{} = now),
    do: DateTime.compare(resets_at, now) == :gt

  @doc """
  Returns the sentence that tells the user the limit is reached, when it resets, and how to continue.

  For example: "Your ChatGPT Pro usage limit is reached. It resets Wed, Nov 25 at 10:01 AM. Choose another model with /model to continue now." The reset is a local clock time, with the date when it is not on the same local day as `now`, and is left out when unknown.
  """
  @spec message(t(), DateTime.t(), PlanWindow.to_local()) :: String.t()
  def message(%__MODULE__{} = limit, %DateTime{} = now, to_local) when is_function(to_local, 1) do
    [
      "Your #{subscription(limit)} usage limit is reached.",
      reset_sentence(limit.resets_at, now, to_local),
      "Choose another model with /model to continue now."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @spec subscription(t()) :: String.t()
  defp subscription(%__MODULE__{service: service, plan: nil}), do: service

  defp subscription(%__MODULE__{service: service, plan: plan}),
    do: "#{service} #{plan_label(plan)}"

  @spec plan_label(String.t()) :: String.t()
  defp plan_label(plan) do
    plan
    |> String.split(["_", "-", " "], trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @spec reset_sentence(DateTime.t() | nil, DateTime.t(), PlanWindow.to_local()) ::
          String.t() | nil
  defp reset_sentence(nil, _now, _to_local), do: nil

  defp reset_sentence(resets_at, now, to_local) do
    {reset_date, {hour, minute, _second}} = to_local.(resets_at)
    {today, _time} = to_local.(now)
    time = clock(hour, minute)

    if reset_date == today,
      do: "It resets at #{time}.",
      else: "It resets #{day(reset_date)} at #{time}."
  end

  @spec clock(0..23, 0..59) :: String.t()
  defp clock(hour, minute) do
    meridiem = if hour < 12, do: "AM", else: "PM"

    "#{rem(hour + 11, 12) + 1}:#{String.pad_leading(Integer.to_string(minute), 2, "0")} #{meridiem}"
  end

  @spec day(:calendar.date()) :: String.t()
  defp day({_year, month, day_of_month} = date) do
    weekday = Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), :calendar.day_of_the_week(date) - 1)
    month_name = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), month - 1)
    "#{weekday}, #{month_name} #{day_of_month}"
  end

  @spec window_kind(pos_integer() | nil) :: String.t()
  defp window_kind(nil), do: "plan"

  defp window_kind(minutes) do
    case Map.fetch(@window_kinds, minutes) do
      {:ok, kind} -> kind
      :error -> window_length(minutes)
    end
  end

  @spec window_length(pos_integer()) :: String.t()
  defp window_length(minutes) when rem(minutes, 1_440) == 0, do: "#{div(minutes, 1_440)}d"
  defp window_length(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)}h"
  defp window_length(minutes), do: "#{minutes}m"

  @spec signal?(term()) :: boolean()
  defp signal?(@signal), do: true
  defp signal?(_value), do: false

  @spec error_object(term()) :: map() | nil
  defp error_object(%{"error" => %{} = error}), do: error
  defp error_object(%{error: %{} = error}), do: error
  defp error_object(%{} = body), do: body
  defp error_object(_body), do: nil

  @spec field(map() | nil, String.t()) :: term()
  defp field(nil, _key), do: nil
  defp field(map, key), do: Map.get(map, key)

  @spec plan(term()) :: String.t() | nil
  defp plan(plan) when is_binary(plan) and plan != "", do: plan
  defp plan(_plan), do: nil

  @spec positive_integer(term()) :: pos_integer() | nil
  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  @spec resets_at(map() | nil, DateTime.t()) :: DateTime.t() | nil
  defp resets_at(error, observed_at) do
    with :error <- unix_time(field(error, "resets_at")) do
      reset_after(field(error, "resets_in_seconds"), observed_at)
    end
  end

  @spec unix_time(term()) :: DateTime.t() | :error
  defp unix_time(unix) when is_integer(unix) and unix > 0 do
    case DateTime.from_unix(unix) do
      {:ok, at} -> at
      {:error, _invalid} -> :error
    end
  end

  defp unix_time(_value), do: :error

  @spec reset_after(term(), DateTime.t()) :: DateTime.t() | nil
  defp reset_after(seconds, observed_at) when is_integer(seconds) and seconds >= 0 do
    case unix_time(DateTime.to_unix(observed_at) + seconds) do
      %DateTime{} = at -> at
      :error -> nil
    end
  end

  defp reset_after(_seconds, _observed_at), do: nil
end
