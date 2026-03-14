defmodule Minga.Language.GraphQL do
  @moduledoc "GraphQL language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :graphql,
      label: "GraphQL",
      comment_token: "# ",
      extensions: ["graphql", "gql"],
      icon: "\u{F0877}",
      icon_color: 0xE10098,
      grammar: "graphql"
    }
  end
end
