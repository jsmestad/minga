defmodule Minga.Language.Ini do
  @moduledoc "INI language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :ini,
      label: "INI",
      comment_token: "; ",
      extensions: ["ini"],
      icon: "\u{E615}",
      icon_color: 0x6D8086
    }
  end
end
