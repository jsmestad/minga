defmodule MingaAgent.ArtifactStore.LimitsTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ArtifactStore.Limits

  @defaults %{
    root_bytes: 1000,
    session_bytes: 100,
    capture_bytes: 10,
    append_bytes: 5,
    image_bytes: 6,
    root_namespaces: 4,
    root_artifacts: 10,
    session_artifacts: 2,
    root_open_captures: 10,
    session_open_captures: 2,
    session_pin_sets: 4,
    session_pin_refs: 4,
    root_items: 100,
    session_items: 10,
    capture_items: 5
  }

  test "overrides cannot supply a key missing from the default policy" do
    missing = Map.delete(@defaults, :append_bytes)
    typo = Map.put(missing, :append_byte, 5)

    assert {:error, :invalid_limits} = Limits.new(%{append_bytes: 5}, missing)
    assert {:error, :invalid_limits} = Limits.new(%{append_bytes: 5}, typo)
    assert {:error, :invalid_limits} = Limits.new(@defaults)
  end

  test "validates effective values after the last override wins" do
    defaults = %{@defaults | session_pin_sets: 0}

    assert {:ok, %Limits{session_pin_sets: 2}} =
             Limits.new([session_pin_sets: 0, session_pin_sets: 2], defaults)
  end

  test "rejects malformed override shapes and nonpositive or non-integer values" do
    assert {:ok, ceiling} = Limits.new(%{}, @defaults)

    for overrides <- [
          %{"append_bytes" => 4},
          %{__struct__: Limits, append_bytes: 4},
          [:append_bytes],
          [append_bytes: 0],
          [append_bytes: -1],
          [append_bytes: 1.5]
        ] do
      assert {:error, :invalid_limits} = Limits.new(overrides, @defaults)
      assert {:error, :invalid_limits} = Limits.restrict(ceiling, overrides)
    end
  end

  test "a default may be increased but a ceiling may only be kept or lowered" do
    assert {:ok, %Limits{session_pin_sets: 5}} = Limits.new([session_pin_sets: 5], @defaults)
    assert {:ok, ceiling} = Limits.new(%{}, @defaults)

    assert {:error, :invalid_limits} = Limits.restrict(ceiling, session_pin_sets: 5)
    assert {:ok, ^ceiling} = Limits.restrict(ceiling, session_pin_sets: 4)

    assert {:ok, %Limits{session_pin_sets: 2, session_pin_refs: 4}} =
             Limits.restrict(ceiling, session_pin_sets: 2)
  end

  test "lowering a parent still validates the unchanged child limits" do
    assert {:ok, ceiling} = Limits.new(%{}, @defaults)
    assert {:error, :invalid_limits} = Limits.new([capture_bytes: 5], @defaults)
    assert {:error, :invalid_limits} = Limits.restrict(ceiling, capture_bytes: 5)
  end
end
