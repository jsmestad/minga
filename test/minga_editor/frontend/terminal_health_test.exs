defmodule MingaEditor.Frontend.TerminalHealthTest do
  @moduledoc "What `:checkhealth terminal` says about each terminal feature."
  use ExUnit.Case, async: true

  alias MingaEditor.Frontend.TerminalHealth
  alias MingaEditor.Frontend.TerminalReport

  defp report do
    TerminalReport.new([
      {:true_color, :detected, :answered},
      {:styled_underlines, :detected, :known_terminal},
      {:underline_color, :fallback, :timeout},
      {:kitty_keyboard, :fallback, :timeout},
      {:synchronized_output, :missing, :timeout},
      {:focus_reporting, :pending, :unsettled}
    ])
  end

  defp row(rows, feature), do: Enum.find(rows, &(&1.feature == feature))

  test "there is one row for every feature of the report, in the report's order" do
    assert Enum.map(TerminalHealth.rows(report()), & &1.feature) == TerminalReport.features()
  end

  test "each standing says what Minga uses instead, or what is lost, only when that applies" do
    rows = TerminalHealth.rows(report())

    assert %{standing: :detected, source: :answered, instead: nil} = row(rows, :true_color)

    assert %{standing: :detected, source: :known_terminal, instead: nil} =
             row(rows, :styled_underlines)

    assert %{standing: :fallback, instead: "Minga uses an underline in the text colour."} =
             row(rows, :underline_color)

    assert %{standing: :missing, instead: "Without it, frames may tear on a fast scroll."} =
             row(rows, :synchronized_output)

    assert %{standing: :pending, instead: nil} = row(rows, :focus_reporting)
  end

  test "a feature the frontend does not mention is not used yet, never missing" do
    rows = TerminalHealth.rows(report())

    for feature <- [
          :hyperlinks,
          :desktop_notifications,
          :tab_title,
          :tab_progress,
          :kitty_graphics,
          :clipboard_osc52
        ] do
      assert %{standing: :unused, instead: nil} = row(rows, feature)
    end

    text = report() |> TerminalHealth.lines(%{}) |> Enum.join("\n")
    assert text =~ ~r/Clickable file:line\s+not used yet/
    refute text =~ ~r/Clickable file:line\s+missing/
  end

  test "every status and source of the report has words on the page" do
    for status <- [:pending, :detected, :missing, :fallback],
        source <- [:unsettled, :answered, :known_terminal, :timeout, :user] do
      lines =
        TerminalHealth.lines(TerminalReport.new([{:styled_underlines, status, source}]), %{})

      assert Enum.any?(lines, &(&1 =~ "Curly and dotted underlines"))
    end
  end

  test "the page says how each feature was settled" do
    text = report() |> TerminalHealth.lines(%{}) |> Enum.join("\n")

    assert text =~ ~r/24-bit colour\s+detected\s+the terminal answered/
    assert text =~ ~r/Curly and dotted underlines\s+detected\s+a terminal known to have it/
    assert text =~ ~r/Underline colour\s+fallback\s+the terminal did not answer/
    assert text =~ ~r/Focus awareness\s+asking\s+the terminal has not answered yet/
  end

  test "a forced feature is shown as set in the config" do
    forced = TerminalReport.new([{:styled_underlines, :detected, :user}])
    text = forced |> TerminalHealth.lines(%{styled_underlines: :on}) |> Enum.join("\n")

    assert text =~ ~r/Curly and dotted underlines\s+detected\s+set in your config/
    refute text =~ "not applied"
  end

  test "a feature the option names but the running frontend did not take says what to do" do
    assert TerminalHealth.not_applied(report(), %{styled_underlines: :off, true_color: :on}) ==
             [styled_underlines: :off, true_color: :on]

    applied = TerminalReport.new([{:styled_underlines, :fallback, :user}])
    assert TerminalHealth.not_applied(applied, %{styled_underlines: :off}) == []

    text = report() |> TerminalHealth.lines(%{styled_underlines: :off}) |> Enum.join("\n")
    assert text =~ "Set in your config, not applied: styled_underlines off."
    assert text =~ "Restart Minga to apply it."
    assert text =~ "MINGA_TERMINAL_FEATURES=styled_underlines=off"
  end

  test "a frontend that is not a terminal gets one plain sentence, and no feature rows" do
    lines = TerminalHealth.lines(:not_a_terminal, %{styled_underlines: :on})

    assert Enum.any?(lines, &(&1 =~ "This is not a terminal."))
    refute Enum.any?(lines, &(&1 =~ "24-bit colour"))
    refute Enum.any?(lines, &(&1 =~ "not applied"))
  end

  test "a terminal that has not reported yet says to ask again" do
    lines = TerminalHealth.lines(:no_report, %{})

    assert Enum.any?(lines, &(&1 =~ "has not reported yet"))
    refute Enum.any?(lines, &(&1 =~ "24-bit colour"))
  end
end
