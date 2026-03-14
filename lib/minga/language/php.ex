defmodule Minga.Language.Php do
  @moduledoc "PHP language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :php,
      label: "PHP",
      comment_token: "// ",
      extensions: ["php", "phtml"],
      icon: "\u{E73D}",
      icon_color: 0x777BB3,
      grammar: "php"
    }
  end
end
