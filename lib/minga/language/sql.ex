defmodule Minga.Language.Sql do
  @moduledoc "SQL language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :sql,
      label: "SQL",
      comment_token: "-- ",
      extensions: ["sql"],
      icon: "\u{E706}",
      icon_color: 0xDAD8D8
    }
  end
end
