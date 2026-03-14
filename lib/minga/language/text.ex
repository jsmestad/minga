defmodule Minga.Language.Text do
  @moduledoc "Text language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :text,
      label: "Text",
      comment_token: "# ",
      extensions: ["txt"],
      icon: "\u{E612}",
      icon_color: 0x89E051
    }
  end
end
