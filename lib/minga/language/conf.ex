defmodule Minga.Language.Conf do
  @moduledoc "Config language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :conf,
      label: "Config",
      comment_token: "# ",
      extensions: ["conf", "cfg"],
      icon: "\u{E615}",
      icon_color: 0x6D8086
    }
  end
end
