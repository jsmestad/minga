defmodule Minga.Language.Protobuf do
  @moduledoc "Protobuf language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :protobuf,
      label: "Protobuf",
      comment_token: "// ",
      extensions: ["proto"],
      icon: "\u{F0614}",
      icon_color: 0x6A9FB5
    }
  end
end
