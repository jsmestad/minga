defmodule Minga.Language.Fish do
  @moduledoc "Fish language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :fish,
      label: "Fish",
      comment_token: "# ",
      extensions: ["fish"],
      shebangs: ["fish"],
      icon: "\u{E795}",
      icon_color: 0x89E051
    }
  end
end
