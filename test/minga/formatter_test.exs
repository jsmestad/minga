defmodule Minga.FormatterTest do
  use ExUnit.Case, async: false

  alias Minga.Config.Options
  alias Minga.Formatter

  setup do
    case Options.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Options.reset()
    end

    :ok
  end

  describe "format/2" do
    test "passes content through a command and returns output" do
      assert {:ok, "hello\n"} = Formatter.format("hello\n", "cat")
    end

    test "returns error for non-zero exit code" do
      assert {:error, msg} = Formatter.format("input", "false")
      assert msg =~ "exited with code"
    end

    test "returns error for nonexistent command" do
      assert {:error, msg} = Formatter.format("input", "nonexistent_command_xyz_123")
      assert msg =~ "not found" or msg =~ "error"
    end

    test "handles multi-argument commands" do
      assert {:ok, output} = Formatter.format("hello world\n", "tr a-z A-Z")
      assert output == "HELLO WORLD\n"
    end
  end

  describe "resolve_formatter/2" do
    test "returns default formatter for known filetype" do
      spec = Formatter.resolve_formatter(:elixir, "lib/foo.ex")
      assert spec == "mix format --stdin-filename lib/foo.ex -"
    end

    test "replaces {file} placeholder with file path" do
      spec = Formatter.resolve_formatter(:go, "main.go")
      assert spec == "gofmt"
    end

    test "returns nil for unknown filetype with no user config" do
      assert Formatter.resolve_formatter(:unknown_lang) == nil
    end

    test "user config overrides default formatter" do
      Options.set_for_filetype(:elixir, :formatter, "custom-fmt {file}")
      spec = Formatter.resolve_formatter(:elixir, "test.ex")
      assert spec == "custom-fmt test.ex"
    end

    test "user config with no {file} placeholder is returned as-is" do
      Options.set_for_filetype(:ruby, :formatter, "rubocop --stdin")
      spec = Formatter.resolve_formatter(:ruby, "test.rb")
      assert spec == "rubocop --stdin"
    end
  end

  describe "default_formatters/0" do
    test "returns a map with common languages" do
      defaults = Formatter.default_formatters()
      assert is_map(defaults)
      assert Map.has_key?(defaults, :elixir)
      assert Map.has_key?(defaults, :go)
      assert Map.has_key?(defaults, :rust)
      assert Map.has_key?(defaults, :python)
      assert Map.has_key?(defaults, :zig)
    end
  end

  describe "apply_save_transforms/2" do
    test "trims trailing whitespace when enabled" do
      Options.set_for_filetype(:elixir, :trim_trailing_whitespace, true)

      input = "hello   \nworld  \n"
      result = Formatter.apply_save_transforms(input, :elixir)
      assert result == "hello\nworld\n"
    end

    test "does not trim trailing whitespace when disabled" do
      input = "hello   \nworld  \n"
      result = Formatter.apply_save_transforms(input, :text)
      assert result == "hello   \nworld  \n"
    end

    test "inserts final newline when enabled and missing" do
      Options.set_for_filetype(:elixir, :insert_final_newline, true)

      result = Formatter.apply_save_transforms("hello", :elixir)
      assert result == "hello\n"
    end

    test "does not double final newline when already present" do
      Options.set_for_filetype(:elixir, :insert_final_newline, true)

      result = Formatter.apply_save_transforms("hello\n", :elixir)
      assert result == "hello\n"
    end

    test "does not insert final newline when disabled" do
      result = Formatter.apply_save_transforms("hello", :text)
      assert result == "hello"
    end

    test "both transforms can apply together" do
      Options.set_for_filetype(:go, :trim_trailing_whitespace, true)
      Options.set_for_filetype(:go, :insert_final_newline, true)

      input = "func main() {   \n}  "
      result = Formatter.apply_save_transforms(input, :go)
      assert result == "func main() {\n}\n"
    end
  end
end
