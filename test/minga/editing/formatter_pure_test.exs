defmodule Minga.Editing.FormatterPureTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Formatter

  test "returns the default formatter for a known filetype" do
    assert Formatter.resolve_formatter(:elixir, "lib/foo.ex") ==
             "mix format --stdin-filename lib/foo.ex -"
  end

  test "returns nil for an unknown filetype" do
    assert Formatter.resolve_formatter(:unknown_lang) == nil
  end

  test "default formatters include the supported language families" do
    defaults = Formatter.default_formatters()

    assert Enum.all?([:elixir, :go, :rust, :python, :zig], &Map.has_key?(defaults, &1))
  end

  test "preserves trailing whitespace when trimming is disabled" do
    assert Formatter.apply_save_transforms("hello   \nworld  \n", :text) ==
             "hello   \nworld  \n"
  end

  test "preserves a missing final newline when insertion is disabled" do
    assert Formatter.apply_save_transforms("hello", :text) == "hello"
  end
end
