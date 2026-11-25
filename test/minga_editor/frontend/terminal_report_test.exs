defmodule MingaEditor.Frontend.TerminalReportTest do
  @moduledoc "The terminal frontend's report of its host terminal's features, as the editor reads it off the wire."
  use ExUnit.Case, async: true

  alias Minga.Protocol.Encode
  alias MingaEditor.Frontend.TerminalReport

  defp entry(feature, status, source \\ :answered) do
    <<Encode.encode_terminal_feature(feature), Encode.encode_terminal_feature_status(status),
      Encode.encode_terminal_feature_source(source)>>
  end

  test "decodes a snapshot of features and what is known about each" do
    body =
      <<3, entry(:true_color, :detected)::binary, entry(:kitty_keyboard, :pending)::binary>> <>
        entry(:tab_progress, :fallback)

    assert {:ok, report} = TerminalReport.decode(body)
    assert TerminalReport.status(report, :true_color) == :detected
    assert TerminalReport.status(report, :kitty_keyboard) == :pending
    assert TerminalReport.status(report, :tab_progress) == :fallback
  end

  test "a feature the frontend did not mention is unknown, never missing" do
    assert {:ok, report} = TerminalReport.decode(<<1, entry(:hyperlinks, :missing)::binary>>)

    for feature <- TerminalReport.features() -- [:hyperlinks] do
      assert TerminalReport.status(report, feature) == :unknown
    end

    assert {:ok, empty} = TerminalReport.decode(<<0>>)
    assert Enum.all?(TerminalReport.features(), &(TerminalReport.status(empty, &1) == :unknown))
  end

  test "every feature and every status of the schema survives the wire" do
    for feature <- TerminalReport.features(),
        status <- [:unknown, :pending, :detected, :missing, :fallback] do
      assert {:ok, report} = TerminalReport.decode(<<1, entry(feature, status)::binary>>)
      assert TerminalReport.status(report, feature) == status
    end
  end

  test "a feature this build does not know is skipped, and a status or source it does not know reads as unknown" do
    body =
      <<4, 200, 2, 1, entry(:focus_reporting, :detected)::binary>> <>
        <<Encode.encode_terminal_feature(:clipboard_osc52), 99, 1>> <>
        <<Encode.encode_terminal_feature(:hyperlinks), 2, 99>>

    assert {:ok, report} = TerminalReport.decode(body)

    assert report.features == %{
             focus_reporting: {:detected, :answered},
             clipboard_osc52: {:unknown, :answered},
             hyperlinks: {:detected, :unsettled}
           }
  end

  test "every source of the schema survives the wire, with its status" do
    for source <- [:unsettled, :answered, :known_terminal, :timeout, :user] do
      assert {:ok, report} =
               TerminalReport.decode(<<1, entry(:styled_underlines, :detected, source)::binary>>)

      assert TerminalReport.source(report, :styled_underlines) == source
      assert TerminalReport.entry(report, :styled_underlines) == {:detected, source}
    end

    assert {:ok, empty} = TerminalReport.decode(<<0>>)
    assert TerminalReport.entry(empty, :styled_underlines) == {:unknown, :unsettled}
  end

  test "a report is settled when nothing is still pending" do
    refute TerminalReport.settled?(
             TerminalReport.new(true_color: :detected, kitty_keyboard: :pending)
           )

    assert TerminalReport.settled?(
             TerminalReport.new(true_color: :detected, kitty_keyboard: :fallback)
           )

    assert TerminalReport.settled?(TerminalReport.new([]))
  end

  test "only a changed status is news about what the terminal can do" do
    table = TerminalReport.new([{:styled_underlines, :detected, :known_terminal}])
    answered = TerminalReport.new([{:styled_underlines, :detected, :answered}])
    refused = TerminalReport.new([{:styled_underlines, :fallback, :answered}])

    more =
      TerminalReport.new([
        {:styled_underlines, :detected, :answered},
        {:true_color, :detected, :answered}
      ])

    for {previous, report, news?} <- [
          {nil, table, true},
          {table, table, false},
          {table, answered, false},
          {answered, table, false},
          {table, refused, true},
          {answered, more, true}
        ] do
      assert TerminalReport.statuses_changed?(previous, report) == news?
    end
  end

  test "a later entry for the same feature wins" do
    body = <<2, entry(:true_color, :pending)::binary, entry(:true_color, :detected)::binary>>

    assert {:ok, report} = TerminalReport.decode(body)
    assert TerminalReport.status(report, :true_color) == :detected
  end

  test "a body whose length does not match its count is malformed" do
    for body <- [
          <<>>,
          <<1>>,
          <<2, entry(:true_color, :detected)::binary>>,
          <<0, 1, 2>>,
          <<1, 1, 2>>
        ] do
      assert TerminalReport.decode(body) == {:error, :malformed}
    end
  end
end
