defmodule Minga.Language.Csv do
  @moduledoc "CSV language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :csv,
      label: "CSV",
      comment_token: "# ",
      extensions: ["csv", "tsv"],
      icon: "\u{F0CE}",
      icon_color: 0x89E051
    }
  end
end
