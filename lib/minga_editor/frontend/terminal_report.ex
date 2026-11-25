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

  @type t :: %__MODULE__{features: %{feature() => status()}}

  defstruct features: %{}

  # The wire bytes come from the schema's enums, so this module cannot disagree with the frontends about a value.
  @feature_by_byte Map.new(@features, &{Encode.encode_terminal_feature(&1), &1})
  @status_by_byte Map.new(@statuses, &{Encode.encode_terminal_feature_status(&1), &1})

  @doc "The features a report can hold, in the order they are listed to the user."
  @spec features() :: [feature()]
  def features, do: @features

  @doc "Builds a report from `{feature, status}` pairs. A later pair for the same feature wins."
  @spec new([{feature(), status()}]) :: t()
  def new(entries) when is_list(entries) do
    %__MODULE__{
      features:
        for {feature, status} <- entries, feature in @features, status in @statuses, into: %{} do
          {feature, status}
        end
    }
  end

  @doc "Returns what the report says about one feature. A feature the frontend did not mention is `:unknown`."
  @spec status(t(), feature()) :: status()
  def status(%__MODULE__{features: features}, feature) when feature in @features,
    do: Map.get(features, feature, :unknown)

  @doc """
  Decodes the body of a `terminal_report` event: a count, then `feature(u8) + status(u8)` entries.

  A feature this build does not know is skipped, so a newer frontend's entry cannot be mistaken for another feature. A status it does not know reads as `:unknown`. A body whose length does not match its count is malformed.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :malformed}
  def decode(<<count::8, entries::binary>>) when byte_size(entries) == count * 2 do
    pairs =
      for <<feature::8, status::8 <- entries>>, Map.has_key?(@feature_by_byte, feature) do
        {Map.fetch!(@feature_by_byte, feature), Map.get(@status_by_byte, status, :unknown)}
      end

    {:ok, new(pairs)}
  end

  def decode(body) when is_binary(body), do: {:error, :malformed}
end
