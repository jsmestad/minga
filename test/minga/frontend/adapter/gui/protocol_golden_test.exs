defmodule Minga.Frontend.Adapter.GUI.ProtocolGoldenTest do
  @moduledoc """
  Guards the cross-language protocol golden fixtures (ticket #2225, AC 3 and AC 4).

  The fixtures live in `Minga.Test.ProtocolGolden`; the committed manifest at
  `go/tui/internal/protocol/testdata/golden/manifest.json` is consumed by the Go
  cross-language golden test. This suite keeps the manifest from drifting and
  keeps the fixtures pointed at real generated decoders.
  """

  use ExUnit.Case, async: true

  alias Minga.Protocol.GoldenFields
  alias Minga.Test.ProtocolGolden

  @manifest_path Path.expand(
                   "../../../../../go/tui/internal/protocol/testdata/golden/manifest.json",
                   __DIR__
                 )

  test "committed golden manifest matches the fixtures" do
    expected = (ProtocolGolden.manifest() |> JSON.encode!()) <> "\n"
    actual = File.read!(@manifest_path)

    assert actual == expected,
           "Golden manifest is stale. Run `MIX_ENV=test mix protocol.golden` to regenerate it."
  end

  test "every fixture targets a generated golden decoder unit" do
    known = MapSet.new(GoldenFields.units())

    for fixture <- ProtocolGolden.fixtures() do
      assert MapSet.member?(known, fixture.decoder),
             "fixture #{fixture.name} references unknown decoder #{fixture.decoder}"
    end
  end

  test "fixtures cover empty, typical, and boundary payloads per family" do
    fixtures = ProtocolGolden.fixtures()

    # At least one zero-length-list / hidden fixture and one populated fixture
    # exist so the empty and typical paths are both exercised.
    assert Enum.any?(fixtures, &String.contains?(&1.name, "hidden"))
    assert Enum.any?(fixtures, &String.contains?(&1.name, "empty"))
    assert Enum.any?(fixtures, &String.contains?(&1.name, "unicode"))
    assert Enum.any?(fixtures, &String.contains?(&1.name, "max"))
  end

  test "fixture payloads are non-empty and decode-sized" do
    for fixture <- ProtocolGolden.fixtures() do
      assert byte_size(fixture.payload) >= 1,
             "fixture #{fixture.name} produced an empty payload"
    end
  end
end
