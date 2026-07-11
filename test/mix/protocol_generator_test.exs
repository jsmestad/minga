Code.require_file("mix/protocol_generator.ex")

defmodule Minga.Mix.ProtocolGeneratorTest do
  use ExUnit.Case, async: true

  alias Minga.Mix.ProtocolGenerator
  alias Minga.Protocol.EncodingError

  @fixture_path "test/fixtures/protocol_encoder_bounds.toml"
  @encoder Minga.ProtocolFixture.Encode

  setup_all do
    {:ok, schema} = @fixture_path |> File.read!() |> Toml.decode()
    compile_encoder(schema, @encoder)
    %{schema: schema}
  end

  test "validates every bounded numeric primitive from the schema" do
    for {field, actual, max} <- [
          {:tiny, 256, 255},
          {:small, 65_536, 65_535},
          {:color, 16_777_216, 16_777_215},
          {:large, 4_294_967_296, 4_294_967_295},
          {:huge, 18_446_744_073_709_551_616, 18_446_744_073_709_551_615}
        ] do
      assert_error(%{valid_model() | field => actual}, [field], actual, max)
    end
  end

  test "validates string byte lengths at their schema path" do
    assert_error(
      %{valid_model() | title: String.duplicate("x", 65_536)},
      [:title],
      65_536,
      65_535
    )
  end

  test "recurses through nested structs and counted array elements" do
    assert_error(
      put_in(valid_model(), [:child, :label], String.duplicate("x", 256)),
      [:child, :label],
      256,
      255
    )

    assert_error(
      put_in(valid_model(), [:children, Access.at(0), :score], 65_536),
      [:children, 0, :score],
      65_536,
      65_535
    )
  end

  test "validates counted array prefixes" do
    assert_error(
      %{valid_model() | children: List.duplicate(valid_child(), 256)},
      [:children],
      256,
      255
    )
  end

  test "validates fields in an active conditional tail" do
    model =
      valid_model()
      |> Map.put(:tiny, 1)
      |> Map.put(:conditional_note, String.duplicate("x", 256))

    assert_error(model, [:conditional_note], 256, 255)
  end

  test "a newly added schema field is enforced by regeneration alone", %{schema: schema} do
    module = Minga.ProtocolFixture.ExtendedEncode
    future_field = %{"name" => "future_sequence", "type" => "u16"}

    extended_schema =
      update_in(schema, ["command_fields", Access.at(0), "fields"], fn fields ->
        List.insert_at(fields, -1, future_field)
      end)

    compile_encoder(extended_schema, module)
    model = Map.put(valid_model(), :future_sequence, 65_536)

    assert %EncodingError{
             command: :fixture_command,
             field: :future_sequence,
             field_path: [:future_sequence],
             actual: 65_536,
             max: 65_535
           } =
             assert_raise(EncodingError, fn -> encode_fixture_command(module, model) end)
  end

  defp encode_fixture_command(module, model), do: module.encode_fixture_command(model)

  defp assert_error(model, field_path, actual, max) do
    assert %EncodingError{
             command: :fixture_command,
             field: field,
             field_path: ^field_path,
             actual: ^actual,
             min: 0,
             max: ^max
           } =
             assert_raise(EncodingError, fn -> encode_fixture_command(@encoder, model) end)

    assert field == Enum.find(Enum.reverse(field_path), &is_atom/1)
  end

  defp valid_model do
    %{
      tiny: 0,
      small: 0,
      color: 0,
      large: 0,
      huge: 0,
      title: "title",
      child: valid_child(),
      children: [valid_child()]
    }
  end

  defp valid_child, do: %{score: 1, label: "child"}

  defp compile_encoder(schema, module) do
    schema
    |> ProtocolGenerator.render_encode_module(module)
    |> Code.compile_string()

    :ok
  end
end
