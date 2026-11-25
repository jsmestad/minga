defmodule MingaEditor.Frontend.TerminalHealth do
  @moduledoc """
  What `:checkhealth terminal` says: each terminal feature, whether this terminal has it, how that was settled, and what Minga uses instead.

  The report (`MingaEditor.Frontend.TerminalReport`) is the frontend's own value, so the page states what the frontend does. The wording here is the product's and follows `docs/design/tui.md` ("Terminal capabilities"). A feature the frontend does not mention is not used yet, which is different from a terminal that lacks it.
  """

  alias MingaEditor.Frontend.TerminalOverrides
  alias MingaEditor.Frontend.TerminalReport

  @typedoc """
  Where the page gets its facts. `:not_a_terminal`: the frontend draws in a native window. `:no_report`: a terminal frontend that has not reported yet. Otherwise the frontend's report.
  """
  @type subject :: :not_a_terminal | :no_report | TerminalReport.t()

  @typedoc "How a feature stands. `:unused`: this version of Minga does not use the feature in a terminal yet."
  @type standing :: :detected | :fallback | :missing | :pending | :unused

  @typedoc "One line of the page about one feature."
  @type row :: %{
          feature: TerminalReport.feature(),
          name: String.t(),
          standing: standing(),
          source: TerminalReport.source(),
          instead: String.t() | nil
        }

  # {feature, what it gives, what Minga uses when the terminal lacks it (nil: nothing replaces it), what is lost}.
  @wording [
    {:true_color, "24-bit colour", "256 or 16 colours", nil},
    {:styled_underlines, "Curly and dotted underlines", "a plain underline", nil},
    {:underline_color, "Underline colour", "an underline in the text colour", nil},
    {:hyperlinks, "Clickable file:line", "plain text; gf still opens it", nil},
    {:kitty_keyboard, "Every key as pressed",
     "legacy keys: no ⌘ shortcuts, and Esc on its own waits 50 ms", nil},
    {:desktop_notifications, "\"Needs you\" outside the window", "the bell and the title", nil},
    {:tab_title, "Tab title", nil, "no title in the terminal's tab"},
    {:tab_progress, "Progress in the tab", "progress in the modeline only", nil},
    {:kitty_graphics, "Exact twist in the gutter", "two-tone cells", nil},
    {:synchronized_output, "Flicker-free frames", nil, "frames may tear on a fast scroll"},
    {:focus_reporting, "Focus awareness", nil,
     "nothing dims when the terminal is in the background"},
    {:clipboard_osc52, "Clipboard through the terminal", "the system clipboard tool", nil}
  ]

  @doc "Returns one row per feature, in the order the page lists them."
  @spec rows(TerminalReport.t()) :: [row()]
  def rows(%TerminalReport{} = report) do
    for {feature, name, replacement, loss} <- @wording do
      {status, source} = TerminalReport.entry(report, feature)
      standing = standing(status)

      %{
        feature: feature,
        name: name,
        standing: standing,
        source: source,
        instead: instead(standing, replacement, loss)
      }
    end
  end

  @doc """
  Returns the settings of the option that the running frontend does not have.

  A setting is in effect when the frontend reports the feature as the user's and its status is what the setting asks for. It is not in effect after the option changed without a restart, and where something other than the BEAM starts the frontend.
  """
  @spec not_applied(TerminalReport.t(), TerminalOverrides.t()) :: [{atom(), :on | :off}]
  def not_applied(%TerminalReport{} = report, overrides) when is_map(overrides) do
    overrides
    |> Enum.reject(fn {feature, setting} ->
      in_effect?(TerminalReport.entry(report, feature), setting)
    end)
    |> Enum.sort()
  end

  @doc """
  Returns the features the running frontend was started with as forced that the option no longer names.

  They stay forced until Minga restarts, because the frontend reads the user's choice once, at its start.
  """
  @spec no_longer_set(TerminalReport.t(), TerminalOverrides.t()) :: [TerminalReport.feature()]
  def no_longer_set(%TerminalReport{} = report, overrides) when is_map(overrides) do
    for feature <- TerminalReport.features(),
        TerminalReport.source(report, feature) == :user,
        not Map.has_key?(overrides, feature),
        do: feature
  end

  @spec in_effect?(TerminalReport.entry(), :on | :off) :: boolean()
  defp in_effect?({:detected, :user}, :on), do: true
  defp in_effect?({status, :user}, :off) when status in [:fallback, :missing], do: true
  defp in_effect?(_entry, _setting), do: false

  @doc "Returns the page as text, one line per list element."
  @spec lines(subject(), TerminalOverrides.t()) :: [String.t()]
  def lines(:not_a_terminal, _overrides) do
    [
      "Terminal",
      "",
      "This is not a terminal. The window draws everything itself, so there is nothing to detect and nothing falls back."
    ]
  end

  def lines(:no_report, _overrides) do
    [
      "Terminal",
      "",
      "The terminal frontend has not reported yet. Run :checkhealth terminal again in a moment."
    ]
  end

  def lines(%TerminalReport{} = report, overrides) when is_map(overrides) do
    ["Terminal", ""] ++
      Enum.flat_map(rows(report), &row_lines/1) ++
      not_applied_lines(not_applied(report, overrides)) ++
      no_longer_set_lines(no_longer_set(report, overrides)) ++ footer()
  end

  @spec standing(TerminalReport.status()) :: standing()
  defp standing(:unknown), do: :unused
  defp standing(status) when status in [:detected, :fallback, :missing, :pending], do: status

  @spec instead(standing(), String.t() | nil, String.t() | nil) :: String.t() | nil
  defp instead(:fallback, replacement, _loss) when is_binary(replacement),
    do: "Minga uses #{replacement}."

  defp instead(:missing, _replacement, loss) when is_binary(loss), do: "Without it, #{loss}."
  defp instead(_standing, _replacement, _loss), do: nil

  @spec row_lines(row()) :: [String.t()]
  defp row_lines(%{standing: :unused, name: name}),
    do: ["  ·  #{String.pad_trailing(name, 32)} not used yet"]

  defp row_lines(%{name: name, standing: standing, source: source, instead: instead}) do
    head =
      "  #{mark(standing)}  #{String.pad_trailing(name, 32)} #{String.pad_trailing(word(standing), 10)} #{because(standing, source)}"

    # The detail starts at the row's own indent: deeper leading space would be drawn with indent guides through it.
    [String.trim_trailing(head) | List.wrap(instead && "  └  #{instead}")]
  end

  @spec mark(standing()) :: String.t()
  defp mark(:detected), do: "✓"
  defp mark(:fallback), do: "~"
  defp mark(:missing), do: "✗"
  defp mark(:pending), do: "…"

  @spec word(standing()) :: String.t()
  defp word(:detected), do: "detected"
  defp word(:fallback), do: "fallback"
  defp word(:missing), do: "missing"
  defp word(:pending), do: "asking"

  @spec because(standing(), TerminalReport.source()) :: String.t()
  defp because(_standing, :user), do: "set in your config"
  defp because(_standing, :answered), do: "the terminal answered"
  defp because(_standing, :known_terminal), do: "a terminal known to have it"
  defp because(_standing, :timeout), do: "the terminal did not answer"
  defp because(:pending, :unsettled), do: "the terminal has not answered yet"
  defp because(_standing, :unsettled), do: ""

  @spec not_applied_lines([{atom(), :on | :off}]) :: [String.t()]
  defp not_applied_lines([]), do: []

  defp not_applied_lines(pending) do
    settings = Enum.map_join(pending, ", ", fn {feature, setting} -> "#{feature} #{setting}" end)

    [
      "",
      "Set in your config, not applied: #{settings}.",
      "Restart Minga to apply it. If something else starts Minga's terminal frontend, set #{TerminalOverrides.variable()} yourself, for example #{example(pending)}."
    ]
  end

  @spec no_longer_set_lines([TerminalReport.feature()]) :: [String.t()]
  defp no_longer_set_lines([]), do: []

  defp no_longer_set_lines(features) do
    [
      "",
      "Forced when Minga started, no longer in your config: #{Enum.join(features, ", ")}.",
      "Restart Minga to let it detect them again."
    ]
  end

  @spec example([{atom(), :on | :off}]) :: String.t()
  defp example(pending) do
    [{_variable, value}] = TerminalOverrides.env(Map.new(pending))
    "#{TerminalOverrides.variable()}=#{value}"
  end

  @spec footer() :: [String.t()]
  defp footer do
    [
      "",
      "Is a line wrong for your terminal? Force it in your config, then restart Minga:",
      "  set :terminal_features, %{styled_underlines: :on}",
      "true_color, styled_underlines and underline_color can be forced :on or :off: those are the ones Minga decides",
      "how to draw. The terminal itself turns the others on and answers for them, so forcing them would only make",
      "this page disagree with what happens.",
      "",
      "Run :checkhealth terminal again after changing terminals."
    ]
  end
end
