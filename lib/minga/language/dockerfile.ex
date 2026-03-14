defmodule Minga.Language.Dockerfile do
  @moduledoc "Dockerfile language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :dockerfile,
      label: "Dockerfile",
      comment_token: "# ",
      extensions: ["dockerfile"],
      filenames: ["Dockerfile"],
      icon: "\u{F0868}",
      icon_color: 0x0DB7ED,
      grammar: "dockerfile"
    }
  end
end
