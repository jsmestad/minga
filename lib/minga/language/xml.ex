defmodule Minga.Language.Xml do
  @moduledoc "XML language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :xml,
      label: "XML",
      comment_token: "<!-- ",
      extensions: ["xml", "svg"],
      icon: "\u{F05C0}",
      icon_color: 0xE37933
    }
  end
end
