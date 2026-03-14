defmodule Minga.Language.Dart do
  @moduledoc "Dart language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :dart,
      label: "Dart",
      comment_token: "// ",
      extensions: ["dart"],
      icon: "\u{E798}",
      icon_color: 0x03589C,
      grammar: "dart"
    }
  end
end
