defmodule Minga.LSP.LocationTest do
  use ExUnit.Case, async: true

  alias Minga.LSP.Location

  test "decodes a Location without changing its URI or position" do
    uri = "file:///tmp/with%20space.ex"
    location = %{"uri" => uri, "range" => range(10, 5)}

    assert Location.decode(location) == {uri, 10, 5}
  end

  test "uses a LocationLink's target range, not either selection range" do
    uri = "file:///tmp/target.ex"

    link = %{
      "targetUri" => uri,
      "targetRange" => range(42, 2),
      "targetSelectionRange" => range(43, 6),
      "originSelectionRange" => range(5, 0)
    }

    assert Location.decode(link) == {uri, 42, 2}
  end

  test "a Location takes precedence when a map also has LocationLink keys" do
    location = %{
      "uri" => "file:///tmp/location.ex",
      "range" => nil,
      "targetUri" => "file:///tmp/link.ex",
      "targetRange" => range(2, 7)
    }

    assert Location.decode(location) == {"file:///tmp/location.ex", 0, 0}
  end

  test "selects the first response item, not the first decodable item" do
    first = %{"uri" => "file:///tmp/first.ex", "range" => range(1, 0)}
    second = %{"uri" => "file:///tmp/second.ex", "range" => range(20, 3)}

    assert Location.first(first) == {"file:///tmp/first.ex", 1, 0}
    assert Location.first([first, second]) == {"file:///tmp/first.ex", 1, 0}
    assert Location.first([%{first | "range" => nil}, second]) == {"file:///tmp/first.ex", 0, 0}

    for response <- [[], nil, "garbage", [%{}, second], [[first], second]] do
      assert Location.first(response) == nil
    end
  end

  test "defaults a missing or incomplete start only for a recognized location" do
    uri = "file:///tmp/target.ex"

    for {uri_key, range_key} <- [{"uri", "range"}, {"targetUri", "targetRange"}] do
      for missing_start <- [nil, %{}, %{"start" => %{"line" => 4}}] do
        assert Location.decode(%{uri_key => uri, range_key => missing_start}) == {uri, 0, 0}
      end

      assert Location.decode(%{uri_key => uri}) == nil
    end
  end

  defp range(line, col) do
    %{
      "start" => %{"line" => line, "character" => col},
      "end" => %{"line" => line, "character" => col + 8}
    }
  end
end
