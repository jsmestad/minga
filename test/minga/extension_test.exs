defmodule Minga.ExtensionTest do
  use ExUnit.Case, async: true

  describe "option/3 DSL macro" do
    defmodule TestExtension do
      use Minga.Extension

      option(:conceal, :boolean,
        default: true,
        description: "Hide markup delimiters"
      )

      option(:bullets, :string_list,
        default: ["◉", "○"],
        description: "Unicode bullets for headings"
      )

      option(:format, {:enum, [:html, :pdf]},
        default: :html,
        description: "Default export format"
      )

      @impl true
      def name, do: :test_ext

      @impl true
      def description, do: "Test extension"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates __option_schema__/0 with all declared options" do
      schema = TestExtension.__option_schema__()

      assert schema == [
               {:conceal, :boolean, true, "Hide markup delimiters"},
               {:bullets, :string_list, ["◉", "○"], "Unicode bullets for headings"},
               {:format, {:enum, [:html, :pdf]}, :html, "Default export format"}
             ]
    end

    test "options are in declaration order" do
      names = TestExtension.__option_schema__() |> Enum.map(&elem(&1, 0))
      assert names == [:conceal, :bullets, :format]
    end

    test "descriptions are preserved" do
      descs = TestExtension.__option_schema__() |> Enum.map(&elem(&1, 3))

      assert descs == [
               "Hide markup delimiters",
               "Unicode bullets for headings",
               "Default export format"
             ]
    end
  end

  describe "extension without options" do
    defmodule BareExtension do
      use Minga.Extension

      @impl true
      def name, do: :bare

      @impl true
      def description, do: "No options"

      @impl true
      def version, do: "0.1.0"

      @impl true
      def init(_config), do: {:ok, %{}}
    end

    test "generates empty __option_schema__/0" do
      assert BareExtension.__option_schema__() == []
    end
  end
end
