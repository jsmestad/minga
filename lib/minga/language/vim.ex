defmodule Minga.Language.Vim do
  @moduledoc "Vim language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :vim,
      label: "Vim",
      comment_token: "\" ",
      extensions: ["vim"],
      icon: "\u{E62B}",
      icon_color: 0x019833
    }
  end
end
