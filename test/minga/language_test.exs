defmodule Minga.LanguageTest do
  use ExUnit.Case, async: true

  alias Minga.Language

  describe "struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(Language, %{name: :test})
      end
    end

    test "creates with required keys" do
      lang = %Language{name: :test, label: "Test", comment_token: "# "}
      assert lang.name == :test
      assert lang.label == "Test"
      assert lang.comment_token == "# "
    end

    test "defaults are applied" do
      lang = %Language{name: :test, label: "Test", comment_token: "# "}
      assert lang.extensions == []
      assert lang.filenames == []
      assert lang.shebangs == []
      assert lang.tab_width == 2
      assert lang.indent_with == :spaces
      assert lang.language_servers == []
      assert lang.root_markers == []
      assert lang.icon == nil
      assert lang.icon_color == nil
      assert lang.grammar == nil
      assert lang.formatter == nil
      assert lang.project_type == nil
    end
  end
end
