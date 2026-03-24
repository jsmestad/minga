defmodule Minga.Config.CompletionTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Completion, as: ConfigCompletion
  alias Minga.Config.Options

  describe "option_name_items/0" do
    test "returns items for all valid option names" do
      items = ConfigCompletion.option_name_items()
      valid_names = Options.valid_names()

      assert length(items) == length(valid_names)

      item_names =
        Enum.map(items, fn item ->
          item.label |> String.trim_leading(":") |> String.to_existing_atom()
        end)

      for name <- valid_names do
        assert name in item_names, "missing option: #{inspect(name)}"
      end
    end

    test "items have correct structure" do
      items = ConfigCompletion.option_name_items()
      item = Enum.find(items, fn i -> i.label == ":tab_width" end)

      assert item != nil
      assert item.kind == :property
      assert item.insert_text == ":tab_width"
      assert item.filter_text == "tab_width"
      assert item.detail == "positive integer"
      assert item.documentation =~ "Number of spaces per tab stop"
      assert item.documentation =~ "**Default:** `2`"
      assert item.text_edit == nil
      assert item.raw == nil
    end

    test "items are sorted by name" do
      items = ConfigCompletion.option_name_items()
      names = Enum.map(items, & &1.sort_text)
      assert names == Enum.sort(names)
    end

    test "enum type detail shows all variants" do
      items = ConfigCompletion.option_name_items()
      item = Enum.find(items, fn i -> i.label == ":line_numbers" end)

      assert item.detail =~ ":hybrid"
      assert item.detail =~ ":absolute"
      assert item.detail =~ ":relative"
      assert item.detail =~ ":none"
    end

    test "boolean type detail shows 'boolean'" do
      items = ConfigCompletion.option_name_items()
      item = Enum.find(items, fn i -> i.label == ":autopair" end)

      assert item.detail == "boolean"
    end
  end

  describe "option_value_items/1" do
    test "returns enum values for enum options" do
      items = ConfigCompletion.option_value_items(:line_numbers)

      labels = Enum.map(items, & &1.label)
      assert ":hybrid" in labels
      assert ":absolute" in labels
      assert ":relative" in labels
      assert ":none" in labels
    end

    test "marks default enum value" do
      items = ConfigCompletion.option_value_items(:line_numbers)
      default_item = Enum.find(items, fn i -> i.label == ":hybrid" end)

      assert default_item.detail == "(default)"
    end

    test "non-default enum values have empty detail" do
      items = ConfigCompletion.option_value_items(:line_numbers)
      other_item = Enum.find(items, fn i -> i.label == ":absolute" end)

      assert other_item.detail == ""
    end

    test "returns true/false for boolean options" do
      items = ConfigCompletion.option_value_items(:autopair)

      labels = Enum.map(items, & &1.label)
      assert "true" in labels
      assert "false" in labels
      assert length(items) == 2
    end

    test "marks default boolean value" do
      items = ConfigCompletion.option_value_items(:autopair)
      default_item = Enum.find(items, fn i -> i.label == "true" end)

      assert default_item.detail == "(default)"
    end

    test "returns theme names for theme option" do
      items = ConfigCompletion.option_value_items(:theme)

      labels = Enum.map(items, & &1.label)
      assert ":doom_one" in labels
      assert items != []
    end

    test "returns empty list for string options" do
      assert ConfigCompletion.option_value_items(:font_family) == []
    end

    test "returns empty list for integer options" do
      assert ConfigCompletion.option_value_items(:tab_width) == []
    end

    test "returns empty list for unknown options" do
      assert ConfigCompletion.option_value_items(:nonexistent) == []
    end
  end

  describe "filetype_items/0" do
    test "returns known filetypes" do
      items = ConfigCompletion.filetype_items()

      labels = Enum.map(items, & &1.label)
      assert ":elixir" in labels
      assert ":go" in labels
      assert ":python" in labels
      assert ":javascript" in labels
    end

    test "items have correct structure" do
      items = ConfigCompletion.filetype_items()
      item = Enum.find(items, fn i -> i.label == ":elixir" end)

      assert item != nil
      assert item.kind == :enum_member
      assert item.insert_text == ":elixir"
      assert item.filter_text == "elixir"
      assert item.detail =~ ".ex"
    end

    test "items are sorted" do
      items = ConfigCompletion.filetype_items()
      names = Enum.map(items, & &1.sort_text)
      assert names == Enum.sort(names)
    end

    test "filetype items are unique" do
      items = ConfigCompletion.filetype_items()
      labels = Enum.map(items, & &1.label)
      assert length(labels) == length(Enum.uniq(labels))
    end
  end
end
