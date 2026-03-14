defmodule Minga.Language.Heex do
  @moduledoc "HEEx language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :heex,
      label: "HEEx",
      comment_token: "<%!-- ",
      extensions: ["heex", "leex"],
      icon: "\u{E62D}",
      icon_color: 0x9B59B6,
      grammar: "heex"
    }
  end
end
