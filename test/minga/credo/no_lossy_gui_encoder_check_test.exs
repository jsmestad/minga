Code.require_file("credo/checks/no_lossy_gui_encoder_check.exs")

defmodule Minga.Credo.NoLossyGuiEncoderCheckTest do
  use Credo.Test.Case, async: true

  alias Minga.Credo.NoLossyGuiEncoderCheck

  @moduletag :credo

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp check(source_code, filename \\ "lib/minga/frontend/adapter/gui/example_encoder.ex") do
    source_code
    |> to_source_file(filename)
    |> run_check(NoLossyGuiEncoderCheck, [])
  end

  test "flags lossy GUI encoder helpers" do
    """
    defmodule Minga.Frontend.Adapter.GUI.ExampleEncoder do
      def encode(value), do: Wire.clamp_u16(value)
    end
    """
    |> check()
    |> assert_issue(fn issue -> assert issue.trigger == "clamp_u16" end)
  end

  test "flags direct prefix truncation and min" do
    """
    defmodule Minga.Frontend.Adapter.GUI.ExampleEncoder do
      def encode(value), do: utf8_prefix_bytes(value, min(byte_size(value), 255))
    end
    """
    |> check()
    |> assert_issues(fn issues ->
      assert Enum.map(issues, & &1.trigger) |> Enum.sort() == ["min", "utf8_prefix_bytes"]
    end)
  end

  test "flags direct validation, collection truncation, and dynamic wire fields" do
    """
    defmodule Minga.Frontend.Adapter.GUI.ExampleEncoder do
      def encode(value, items) do
        Wire.validate_uint!(:gui_example, :value, value, 255)
        Enum.take(items, 255)
        <<value::8, 1::8>>
      end
    end
    """
    |> check()
    |> assert_issues(fn issues ->
      assert Enum.map(issues, & &1.trigger) |> Enum.sort() == ["::8", "take", "validate_uint!"]
    end)
  end

  test "flags bitwise masking of a data-derived value" do
    """
    defmodule Minga.Frontend.Adapter.GUI.ExampleEncoder do
      def encode(value), do: value &&& 0xFF
    end
    """
    |> check()
    |> assert_issue(fn issue -> assert issue.trigger == "&&&" end)
  end

  test "flags direct generic Wire carriers and color masking" do
    """
    defmodule Minga.Frontend.Adapter.GUI.ExampleEncoder do
      def encode(value) do
        Wire.encode_string8(value)
        Wire.encode_string16(value)
        Wire.encode_section(1, value)
        Wire.rgb(value)
      end
    end
    """
    |> check()
    |> assert_issues(fn issues ->
      assert Enum.map(issues, & &1.trigger) |> Enum.sort() == [
               "encode_section",
               "encode_string16",
               "encode_string8",
               "rgb"
             ]
    end)
  end

  test "flags every dynamic bounded wire width" do
    """
    defmodule Minga.Frontend.Adapter.GUI.ExampleEncoder do
      def encode(value), do: <<value::24, value::64, value::signed-32, 1::24, @fixed::64>>
    end
    """
    |> check()
    |> assert_issues(fn issues ->
      assert Enum.map(issues, & &1.trigger) |> Enum.sort() == ["::24", "::32-signed", "::64"]
    end)
  end

  test "allows the checked writer" do
    """
    defmodule Minga.Frontend.Adapter.GUI.ExampleEncoder do
      def encode(value), do: Writer.new(:gui_example) |> Writer.uint16(:value, value) |> Writer.finish()
    end
    """
    |> check()
    |> refute_issues()
  end

  test "skips non-GUI adapter files" do
    """
    defmodule Minga.Other do
      def encode(value), do: min(value, 255)
    end
    """
    |> check("lib/minga/other.ex")
    |> refute_issues()
  end
end
