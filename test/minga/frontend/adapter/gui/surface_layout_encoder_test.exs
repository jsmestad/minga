defmodule Minga.Frontend.Adapter.GUI.SurfaceLayoutEncoderTest do
  use ExUnit.Case, async: true
  alias Minga.Frontend.Adapter.GUI.{EncodingError, SurfaceLayoutEncoder}
  @u16_fields [:surface_id, :row, :col, :width, :height, :z]
  defp placement,
    do: %{surface_id: 1, rect: %{row: 2, col: 3, width: 40, height: 20}, z: 4, hit_kind: 5}

  test "rejects negative and overflowing values for every bounded field" do
    for field <- @u16_fields ++ [:hit_kind], value <- [-1, 65_536] do
      error =
        assert_raise EncodingError, fn ->
          SurfaceLayoutEncoder.encode_command([put_field(placement(), field, value)])
        end

      assert error.command == :gui_surface_layout
      assert error.field == field
      assert error.actual == value
      assert error.min == 0
      assert error.max == if(field == :hit_kind, do: 255, else: 65_535)
    end
  end

  test "accepts the wire maximum for every bounded field" do
    for field <- @u16_fields,
        do:
          assert(
            is_binary(
              SurfaceLayoutEncoder.encode_command([put_field(placement(), field, 65_535)])
            )
          )

    assert is_binary(
             SurfaceLayoutEncoder.encode_command([put_field(placement(), :hit_kind, 255)])
           )
  end

  test "formats non-integer values safely in encoding errors" do
    error =
      assert_raise EncodingError, fn ->
        SurfaceLayoutEncoder.encode_command([put_field(placement(), :z, %{})])
      end

    assert Exception.message(error) =~ "z=%{}"
  end

  defp put_field(placement, field, value) when field in [:surface_id, :z, :hit_kind],
    do: Map.put(placement, field, value)

  defp put_field(placement, field, value) when field in [:row, :col, :width, :height],
    do: %{placement | rect: Map.put(placement.rect, field, value)}
end
