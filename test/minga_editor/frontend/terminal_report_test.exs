defmodule MingaEditor.Frontend.TerminalReportTest do
  @moduledoc "The terminal frontend's report of its host terminal's features, as the editor reads it off the wire."
  use ExUnit.Case, async: true

  alias Minga.Protocol.Encode
  alias MingaEditor.Frontend.TerminalReport

  defp entry(feature, status),
    do: <<Encode.encode_terminal_feature(feature), Encode.encode_terminal_feature_status(status)>>

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

  test "a feature this build does not know is skipped, and a status it does not know reads as unknown" do
    body =
      <<3, 200, 2, entry(:focus_reporting, :detected)::binary>> <>
        <<Encode.encode_terminal_feature(:clipboard_osc52), 99>>

    assert {:ok, report} = TerminalReport.decode(body)
    assert report.features == %{focus_reporting: :detected, clipboard_osc52: :unknown}
  end

  test "a later entry for the same feature wins" do
    body = <<2, entry(:true_color, :pending)::binary, entry(:true_color, :detected)::binary>>

    assert {:ok, report} = TerminalReport.decode(body)
    assert TerminalReport.status(report, :true_color) == :detected
  end

  test "a body whose length does not match its count is malformed" do
    for body <- [<<>>, <<1>>, <<2, entry(:true_color, :detected)::binary>>, <<0, 1, 2>>] do
      assert TerminalReport.decode(body) == {:error, :malformed}
    end
  end
end
