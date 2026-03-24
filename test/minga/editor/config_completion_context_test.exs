defmodule Minga.Editor.ConfigCompletionContextTest do
  use ExUnit.Case, async: true

  alias Minga.Editor.CompletionHandling

  describe "detect_config_context/2" do
    test "detects option name after 'set :'" do
      assert CompletionHandling.detect_config_context("set :t", 6) == :option_name
    end

    test "detects option name at the colon" do
      assert CompletionHandling.detect_config_context("set :", 5) == :option_name
    end

    test "detects option name with leading whitespace" do
      assert CompletionHandling.detect_config_context("  set :tab", 10) == :option_name
    end

    test "detects option value after 'set :option_name, '" do
      assert CompletionHandling.detect_config_context("set :tab_width, 4", 17) ==
               {:option_value, :tab_width}
    end

    test "detects option value after 'set :option_name, :'" do
      assert CompletionHandling.detect_config_context("set :theme, :d", 14) ==
               {:option_value, :theme}
    end

    test "detects option value for boolean option" do
      assert CompletionHandling.detect_config_context("set :autopair, t", 16) ==
               {:option_value, :autopair}
    end

    test "detects option value with extra whitespace" do
      assert CompletionHandling.detect_config_context("set :line_numbers,  :r", 22) ==
               {:option_value, :line_numbers}
    end

    test "detects filetype after 'for_filetype :'" do
      assert CompletionHandling.detect_config_context("for_filetype :e", 15) == :filetype
    end

    test "detects filetype at the colon" do
      assert CompletionHandling.detect_config_context("for_filetype :", 14) == :filetype
    end

    test "detects filetype with leading whitespace" do
      assert CompletionHandling.detect_config_context("  for_filetype :go", 18) == :filetype
    end

    test "returns :none for unrelated lines" do
      assert CompletionHandling.detect_config_context("# a comment", 11) == :none
    end

    test "returns :none for empty line" do
      assert CompletionHandling.detect_config_context("", 0) == :none
    end

    test "returns :none for 'bind' calls" do
      assert CompletionHandling.detect_config_context("bind :normal, \"SPC g\"", 20) == :none
    end

    test "returns :none for unknown option name in value position" do
      assert CompletionHandling.detect_config_context("set :nonexistent_xyz, :v", 24) == :none
    end

    test "returns :none when cursor is before 'set :'" do
      assert CompletionHandling.detect_config_context("set :tab_width", 3) == :none
    end

    test "handles set with no space before colon" do
      # "set:" is not valid config DSL syntax
      assert CompletionHandling.detect_config_context("set:", 4) == :none
    end
  end
end
