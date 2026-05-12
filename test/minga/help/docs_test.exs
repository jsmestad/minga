defmodule Minga.Help.DocsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Help.Docs

  @doc false
  @spec undocumented_helper() :: :ok
  def undocumented_helper, do: :ok

  describe "format_module/1" do
    test "returns markdown for module docs" do
      content = Docs.format_module(Enum)

      assert content =~ "# Enum"
      assert content =~ "Functions for working with collections"
    end

    test "returns no documentation message for modules without docs" do
      assert Docs.format_module(__MODULE__) == "No documentation available"
    end
  end

  describe "format_function/3" do
    test "returns signature, spec, and markdown docs for a function" do
      content = Docs.format_function(Enum, :map, 2)

      assert content =~ "# Enum.map/2"
      assert content =~ "```elixir\nEnum.map(enumerable, fun)\n```"
      assert content =~ "@spec map("
      assert content =~ "Returns a list"
    end

    test "returns no documentation message for functions without docs" do
      assert Docs.format_function(__MODULE__, :undocumented_helper, 0) ==
               "No documentation available"
    end

    test "returns no documentation message for unknown functions" do
      assert Docs.format_function(Enum, :definitely_missing, 0) == "No documentation available"
    end
  end
end
