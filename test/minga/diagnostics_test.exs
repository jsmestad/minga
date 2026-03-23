defmodule Minga.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic

  setup do
    server = start_supervised!({Diagnostics, name: :"diag_#{System.unique_integer()}"})
    %{server: server}
  end

  defp make_diag(opts \\ []) do
    line = Keyword.get(opts, :line, 0)
    col = Keyword.get(opts, :col, 0)
    end_col = Keyword.get(opts, :end_col, col + 5)

    %Diagnostic{
      range: %{
        start_line: line,
        start_col: col,
        end_line: Keyword.get(opts, :end_line, line),
        end_col: end_col
      },
      severity: Keyword.get(opts, :severity, :error),
      message: Keyword.get(opts, :message, "test error"),
      source: Keyword.get(opts, :source, "test_server"),
      code: Keyword.get(opts, :code, nil)
    }
  end

  @uri "file:///tmp/test.ex"
  @uri2 "file:///tmp/other.ex"

  describe "publish/4 and for_uri/2" do
    test "publishes and retrieves diagnostics", %{server: s} do
      d1 = make_diag(line: 0, message: "error on line 0")
      d2 = make_diag(line: 5, message: "error on line 5")

      assert :ok = Diagnostics.publish(s, :server_a, @uri, [d1, d2])
      result = Diagnostics.for_uri(s, @uri)

      assert length(result) == 2
      assert Enum.at(result, 0).message == "error on line 0"
      assert Enum.at(result, 1).message == "error on line 5"
    end

    test "replaces previous diagnostics for same source+uri", %{server: s} do
      d1 = make_diag(message: "old error")
      d2 = make_diag(message: "new error")

      Diagnostics.publish(s, :server_a, @uri, [d1])
      Diagnostics.publish(s, :server_a, @uri, [d2])

      result = Diagnostics.for_uri(s, @uri)
      assert length(result) == 1
      assert hd(result).message == "new error"
    end

    test "merges diagnostics from multiple sources", %{server: s} do
      d1 = make_diag(line: 1, source: "server_a", message: "from A")
      d2 = make_diag(line: 2, source: "server_b", message: "from B")

      Diagnostics.publish(s, :server_a, @uri, [d1])
      Diagnostics.publish(s, :server_b, @uri, [d2])

      result = Diagnostics.for_uri(s, @uri)
      assert length(result) == 2
      assert Enum.at(result, 0).message == "from A"
      assert Enum.at(result, 1).message == "from B"
    end

    test "returns sorted by line then column", %{server: s} do
      d1 = make_diag(line: 10, col: 0, message: "late")
      d2 = make_diag(line: 1, col: 5, message: "early col 5")
      d3 = make_diag(line: 1, col: 0, message: "early col 0")

      Diagnostics.publish(s, :server_a, @uri, [d1, d2, d3])

      messages = Diagnostics.for_uri(s, @uri) |> Enum.map(& &1.message)
      assert messages == ["early col 0", "early col 5", "late"]
    end

    test "returns empty list for unknown URI", %{server: s} do
      assert Diagnostics.for_uri(s, "file:///nonexistent") == []
    end

    test "different URIs are isolated", %{server: s} do
      d1 = make_diag(message: "file1 error")
      d2 = make_diag(message: "file2 error")

      Diagnostics.publish(s, :server_a, @uri, [d1])
      Diagnostics.publish(s, :server_a, @uri2, [d2])

      assert length(Diagnostics.for_uri(s, @uri)) == 1
      assert hd(Diagnostics.for_uri(s, @uri)).message == "file1 error"
      assert hd(Diagnostics.for_uri(s, @uri2)).message == "file2 error"
    end
  end

  describe "clear/3" do
    test "clears diagnostics for a source+uri pair", %{server: s} do
      Diagnostics.publish(s, :server_a, @uri, [make_diag()])
      assert length(Diagnostics.for_uri(s, @uri)) == 1

      Diagnostics.clear(s, :server_a, @uri)
      assert Diagnostics.for_uri(s, @uri) == []
    end

    test "does not affect other sources for same URI", %{server: s} do
      Diagnostics.publish(s, :server_a, @uri, [make_diag(message: "A")])
      Diagnostics.publish(s, :server_b, @uri, [make_diag(message: "B")])

      Diagnostics.clear(s, :server_a, @uri)

      result = Diagnostics.for_uri(s, @uri)
      assert length(result) == 1
      assert hd(result).message == "B"
    end

    test "clearing nonexistent key is a no-op", %{server: s} do
      assert :ok = Diagnostics.clear(s, :nonexistent, @uri)
    end
  end

  describe "clear_source/2" do
    test "clears all diagnostics from a source across all URIs", %{server: s} do
      Diagnostics.publish(s, :server_a, @uri, [make_diag()])
      Diagnostics.publish(s, :server_a, @uri2, [make_diag()])
      Diagnostics.publish(s, :server_b, @uri, [make_diag(message: "B")])

      Diagnostics.clear_source(s, :server_a)

      assert Diagnostics.for_uri(s, @uri) == [make_diag(message: "B")]
      assert Diagnostics.for_uri(s, @uri2) == []
    end

    test "clearing nonexistent source is a no-op", %{server: s} do
      assert :ok = Diagnostics.clear_source(s, :nonexistent)
    end
  end

  describe "severity_by_line/2" do
    test "returns highest severity per line", %{server: s} do
      d1 = make_diag(line: 1, severity: :warning)
      d2 = make_diag(line: 1, severity: :error)
      d3 = make_diag(line: 5, severity: :info)

      Diagnostics.publish(s, :server_a, @uri, [d1, d2, d3])

      result = Diagnostics.severity_by_line(s, @uri)
      assert result[1] == :error
      assert result[5] == :info
    end

    test "merges across sources", %{server: s} do
      d1 = make_diag(line: 1, severity: :info)
      d2 = make_diag(line: 1, severity: :warning)

      Diagnostics.publish(s, :server_a, @uri, [d1])
      Diagnostics.publish(s, :server_b, @uri, [d2])

      result = Diagnostics.severity_by_line(s, @uri)
      assert result[1] == :warning
    end

    test "returns empty map for unknown URI", %{server: s} do
      assert Diagnostics.severity_by_line(s, "file:///nope") == %{}
    end
  end

  describe "next/3" do
    test "returns the next diagnostic after current line", %{server: s} do
      d1 = make_diag(line: 2, message: "line 2")
      d2 = make_diag(line: 8, message: "line 8")
      Diagnostics.publish(s, :server_a, @uri, [d1, d2])

      result = Diagnostics.next(s, @uri, 3)
      assert result.message == "line 8"
    end

    test "wraps around to first diagnostic when past last", %{server: s} do
      d1 = make_diag(line: 2, message: "line 2")
      d2 = make_diag(line: 8, message: "line 8")
      Diagnostics.publish(s, :server_a, @uri, [d1, d2])

      result = Diagnostics.next(s, @uri, 10)
      assert result.message == "line 2"
    end

    test "returns nil when no diagnostics", %{server: s} do
      assert Diagnostics.next(s, @uri, 0) == nil
    end

    test "wraps when on last diagnostic line", %{server: s} do
      d1 = make_diag(line: 1, message: "first")
      d2 = make_diag(line: 5, message: "last")
      Diagnostics.publish(s, :server_a, @uri, [d1, d2])

      result = Diagnostics.next(s, @uri, 5)
      assert result.message == "first"
    end
  end

  describe "prev/3" do
    test "returns the previous diagnostic before current line", %{server: s} do
      d1 = make_diag(line: 2, message: "line 2")
      d2 = make_diag(line: 8, message: "line 8")
      Diagnostics.publish(s, :server_a, @uri, [d1, d2])

      result = Diagnostics.prev(s, @uri, 5)
      assert result.message == "line 2"
    end

    test "wraps around to last diagnostic when before first", %{server: s} do
      d1 = make_diag(line: 5, message: "line 5")
      d2 = make_diag(line: 10, message: "line 10")
      Diagnostics.publish(s, :server_a, @uri, [d1, d2])

      result = Diagnostics.prev(s, @uri, 3)
      assert result.message == "line 10"
    end

    test "returns nil when no diagnostics", %{server: s} do
      assert Diagnostics.prev(s, @uri, 0) == nil
    end

    test "wraps when on first diagnostic line", %{server: s} do
      d1 = make_diag(line: 1, message: "first")
      d2 = make_diag(line: 5, message: "last")
      Diagnostics.publish(s, :server_a, @uri, [d1, d2])

      result = Diagnostics.prev(s, @uri, 1)
      assert result.message == "last"
    end
  end

  describe "count/2" do
    test "counts diagnostics by severity", %{server: s} do
      diags = [
        make_diag(line: 0, severity: :error),
        make_diag(line: 1, severity: :error),
        make_diag(line: 2, severity: :warning),
        make_diag(line: 3, severity: :info),
        make_diag(line: 4, severity: :hint)
      ]

      Diagnostics.publish(s, :server_a, @uri, diags)

      result = Diagnostics.count(s, @uri)
      assert result == %{error: 2, warning: 1, info: 1, hint: 1}
    end

    test "returns zeros for unknown URI", %{server: s} do
      assert Diagnostics.count(s, @uri) == %{error: 0, warning: 0, info: 0, hint: 0}
    end

    test "counts across multiple sources", %{server: s} do
      Diagnostics.publish(s, :server_a, @uri, [make_diag(severity: :error)])
      Diagnostics.publish(s, :server_b, @uri, [make_diag(severity: :error)])

      result = Diagnostics.count(s, @uri)
      assert result.error == 2
    end
  end

  describe "on_line/3" do
    test "returns diagnostics on a specific line", %{server: s} do
      d1 = make_diag(line: 3, message: "on line 3")
      d2 = make_diag(line: 3, message: "also on line 3", severity: :warning)
      d3 = make_diag(line: 7, message: "on line 7")

      Diagnostics.publish(s, :server_a, @uri, [d1, d2, d3])

      result = Diagnostics.on_line(s, @uri, 3)
      assert length(result) == 2
      messages = Enum.map(result, & &1.message)
      assert "on line 3" in messages
      assert "also on line 3" in messages
    end

    test "returns empty list when no diagnostics on line", %{server: s} do
      Diagnostics.publish(s, :server_a, @uri, [make_diag(line: 5)])
      assert Diagnostics.on_line(s, @uri, 10) == []
    end

    test "merges from multiple sources", %{server: s} do
      Diagnostics.publish(s, :server_a, @uri, [make_diag(line: 1, message: "A")])
      Diagnostics.publish(s, :server_b, @uri, [make_diag(line: 1, message: "B")])

      result = Diagnostics.on_line(s, @uri, 1)
      assert length(result) == 2
    end
  end

  describe "event bus notifications" do
    # Use per-test unique URIs to avoid cross-contamination via the global
    # event bus when running async: true.
    defp unique_uri, do: "file:///tmp/diag_event_#{:erlang.unique_integer([:positive])}.ex"

    test "publish broadcasts :diagnostics_updated event", %{server: s} do
      uri = unique_uri()
      Minga.Events.subscribe(:diagnostics_updated)
      Diagnostics.publish(s, :server_a, uri, [make_diag()])

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: ^uri, source: :server_a}}
    end

    test "clear broadcasts :diagnostics_updated event", %{server: s} do
      uri = unique_uri()
      Minga.Events.subscribe(:diagnostics_updated)
      Diagnostics.publish(s, :server_a, uri, [make_diag()])

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: ^uri}}

      Diagnostics.clear(s, :server_a, uri)

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: ^uri, source: :server_a}}
    end

    test "clear_source broadcasts :diagnostics_updated per affected URI", %{server: s} do
      uri_a = unique_uri()
      uri_b = unique_uri()
      Minga.Events.subscribe(:diagnostics_updated)
      Diagnostics.publish(s, :server_a, uri_a, [make_diag()])
      Diagnostics.publish(s, :server_a, uri_b, [make_diag()])

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: ^uri_a}}

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: ^uri_b}}

      Diagnostics.clear_source(s, :server_a)

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: ^uri_a, source: :server_a}}

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: ^uri_b, source: :server_a}}
    end

    test "event payload includes source field", %{server: s} do
      uri = unique_uri()
      Minga.Events.subscribe(:diagnostics_updated)
      Diagnostics.publish(s, :custom_linter, uri, [make_diag()])

      assert_receive {:minga_event, :diagnostics_updated,
                      %Minga.Events.DiagnosticsUpdatedEvent{uri: ^uri, source: :custom_linter}}
    end
  end

  describe "publishing empty diagnostics" do
    test "publishing empty list clears diagnostics for source+uri", %{server: s} do
      Diagnostics.publish(s, :server_a, @uri, [make_diag()])
      assert length(Diagnostics.for_uri(s, @uri)) == 1

      Diagnostics.publish(s, :server_a, @uri, [])
      assert Diagnostics.for_uri(s, @uri) == []
    end
  end
end
