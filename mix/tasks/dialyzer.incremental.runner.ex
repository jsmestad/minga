defmodule Mix.Tasks.Dialyzer.Incremental.Runner do
  @moduledoc false

  alias Dialyxir.FilterMap
  alias Dialyxir.Formatter

  @dialyxir_args [:raw, :format, :list_unused_filters, :ignore_exit_status, :quiet_with_result]
  @default_formatter Dialyxir.Formatter.Dialyxir

  @type formatted_result ::
          {:ok, {String.t(), [String.t()], String.t()}}
          | {:warn, {String.t(), [String.t()], String.t()}}
          | {:error, {String.t(), String.t()}}
          | {:error, String.t()}

  @spec run(keyword(), module()) :: formatted_result()
  def run(args, filterer) do
    {split, native_args} = Keyword.split(args, @dialyxir_args)
    {duration_us, warnings} = :timer.tc(&:dialyzer.run/1, [native_args])
    elapsed = Formatter.formatted_time(duration_us)
    filter_map_args = FilterMap.to_args(split)

    format_result(
      Formatter.format_and_filter(
        warnings,
        filterer,
        filter_map_args,
        [@default_formatter],
        false
      ),
      elapsed
    )
  catch
    {:dialyzer_error, message} -> {:error, ":dialyzer.run error: " <> to_string(message)}
  end

  defp format_result({:ok, warnings, :no_unused_filters}, elapsed),
    do: {:ok, {elapsed, warnings, ""}}

  defp format_result({:warn, warnings, {:unused_filters_present, unused_filters}}, elapsed) do
    {:ok, {elapsed, warnings, unused_filters}}
  end

  defp format_result({:error, _warnings, {:unused_filters_present, unused_filters}}, _elapsed) do
    {:error, {"unused filters present", unused_filters}}
  end
end
