defmodule Minga.Language.JavaScriptReact do
  @moduledoc "JSX language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :javascript_react,
      label: "JSX",
      comment_token: "// ",
      extensions: ["jsx"],
      icon: "\u{E7BA}",
      icon_color: 0x61DAFB,
      grammar: "javascript",
      formatter: "prettier --stdin-filepath {file}"
    }
  end
end
