defmodule MingaEditor.Frontend.TerminalReport do
  @moduledoc """
  What the terminal frontend knows about the features of its host terminal.

  The terminal frontend detects each feature at startup: some from the environment at once, some from the terminal's answers, which arrive later or never. It sends the whole report after `ready` and again whenever an entry changes, so every report is a complete snapshot. The same value drives the frontend's fallbacks, so what the editor says about a terminal is what the frontend does in it.

  A frontend without a host terminal sends no report. The features and their fallbacks are described in `docs/design/tui.md` ("Terminal capabilities").
  """

  alias Minga.Protocol.Encode

  @features [
    :true_color,
    :styled_underlines,
    :underline_color,
    :hyperlinks,
    :kitty_keyboard,
    :desktop_notifications,
    :tab_title,
    :tab_progress,
    :kitty_graphics,
    :synchronized_output,
    :focus_reporting,
    :clipboard_osc52
  ]

  @statuses [:unknown, :pending, :detected, :missing, :fallback]
  @sources [:unsettled, :answered, :known_terminal, :timeout, :user]

  @typedoc "A terminal feature the frontend detects."
  @type feature ::
          :true_color
          | :styled_underlines
          | :underline_color
          | :hyperlinks
          | :kitty_keyboard
          | :desktop_notifications
          | :tab_title
          | :tab_progress
          | :kitty_graphics
          | :synchronized_output
          | :focus_reporting
          | :clipboard_osc52

  @typedoc """
  What is known about one feature. `:pending`: the terminal was asked and has not answered. `:detected`: the feature is used. `:missing`: the terminal does not have it and nothing replaces it. `:fallback`: Minga uses its documented replacement. `:unknown`: the frontend said nothing about it.
  """
  @type status :: :unknown | :pending | :detected | :missing | :fallback

  @typedoc """
  How the frontend settled a status. `:answered`: the terminal answered a query or showed the feature by using it. `:known_terminal`: the terminal is in the frontend's table of known terminals. `:timeout`: the terminal did not answer in time. `:user`: the user forced it with the `:terminal_features` option. `:unsettled`: nothing is decided yet, or the frontend said nothing about the feature.
  """
  @type source :: :unsettled | :answered | :known_terminal | :timeout | :user

  @typedoc "What the report holds for one feature: its status and how that was settled."
  @type entry :: {status(), source()}

  @type t :: %__MODULE__{features: %{feature() => entry()}}

  defstruct features: %{}

  # The wire bytes come from the schema's enums, so this module cannot disagree with the frontends about a value.
  @feature_by_byte Map.new(@features, &{Encode.encode_terminal_feature(&1), &1})
  @status_by_byte Map.new(@statuses, &{Encode.encode_terminal_feature_status(&1), &1})
  @source_by_byte Map.new(@sources, &{Encode.encode_terminal_feature_source(&1), &1})

  @doc "The features a report can hold, in the order they are listed to the user."
  @spec features() :: [feature()]
  def features, do: @features

  @doc """
  Builds a report from `{feature, status, source}` entries. A later entry for the same feature wins.

  An entry may leave the source out, as `{feature, status}`: it is then `:unsettled`.
  """
  @spec new([{feature(), status(), source()} | {feature(), status()}]) :: t()
  def new(entries) when is_list(entries) do
    %__MODULE__{
      features:
        for entry <- entries,
            {feature, status, source} = with_source(entry),
            feature in @features,
            status in @statuses,
            source in @sources,
            into: %{} do
          {feature, {status, source}}
        end
    }
  end

  @spec with_source({feature(), status(), source()} | {feature(), status()}) ::
          {feature(), status(), source()}
  defp with_source({feature, status}), do: {feature, status, :unsettled}
  defp with_source({_feature, _status, _source} = entry), do: entry

  @doc "Returns what the report says about one feature. A feature the frontend did not mention is `:unknown`."
  @spec status(t(), feature()) :: status()
  def status(%__MODULE__{} = report, feature) when feature in @features,
    do: report |> entry(feature) |> elem(0)

  @doc "Returns how the frontend settled one feature. A feature the frontend did not mention is `:unsettled`."
  @spec source(t(), feature()) :: source()
  def source(%__MODULE__{} = report, feature) when feature in @features,
    do: report |> entry(feature) |> elem(1)

  @doc "Returns the status and source of one feature. A feature the frontend did not mention is `{:unknown, :unsettled}`."
  @spec entry(t(), feature()) :: entry()
  def entry(%__MODULE__{features: features}, feature) when feature in @features,
    do: Map.get(features, feature, {:unknown, :unsettled})

  @doc "Reports whether the terminal has answered, or been given up on, for every feature: nothing is still `:pending`."
  @spec settled?(t()) :: boolean()
  def settled?(%__MODULE__{features: features}),
    do: not Enum.any?(features, fn {_feature, {status, _source}} -> status == :pending end)

  @doc """
  Reports whether a report says something new about what the terminal can do, compared with the report before it.

  A change in how a feature was settled is not such news: a terminal that confirms what the table of known terminals said changes a source and no status. `previous` is `nil` for the first report of a connection.
  """
  @spec statuses_changed?(t() | nil, t()) :: boolean()
  def statuses_changed?(nil, %__MODULE__{}), do: true

  def statuses_changed?(%__MODULE__{} = previous, %__MODULE__{} = report),
    do: statuses(previous) != statuses(report)

  @doc "Returns each mentioned feature with its status, sorted by feature name."
  @spec statuses(t()) :: [{feature(), status()}]
  def statuses(%__MODULE__{features: features}),
    do:
      features
      |> Enum.map(fn {feature, {status, _source}} -> {feature, status} end)
      |> Enum.sort()

  @doc """
  Decodes the body of a `terminal_report` event: a count, then `feature(u8) + status(u8) + source(u8)` entries.

  A feature this build does not know is skipped, so a newer frontend's entry cannot be mistaken for another feature. A status it does not know reads as `:unknown`, and a source it does not know as `:unsettled`. A body whose length does not match its count is malformed.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :malformed}
  def decode(<<count::8, entries::binary>>) when byte_size(entries) == count * 3 do
    decoded =
      for <<feature::8, status::8, source::8 <- entries>>,
          Map.has_key?(@feature_by_byte, feature) do
        {Map.fetch!(@feature_by_byte, feature), Map.get(@status_by_byte, status, :unknown),
         Map.get(@source_by_byte, source, :unsettled)}
      end

    {:ok, new(decoded)}
  end

  def decode(body) when is_binary(body), do: {:error, :malformed}
end
