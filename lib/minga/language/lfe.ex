defmodule Minga.Language.Lfe do
  @moduledoc "LFE language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :lfe,
      label: "LFE",
      comment_token: ";; ",
      extensions: ["lfe"],
      icon: "\u{E7B1}",
      icon_color: 0xA90533
    }
  end
end
