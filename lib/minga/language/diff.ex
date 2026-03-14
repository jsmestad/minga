defmodule Minga.Language.Diff do
  @moduledoc "Diff language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :diff,
      label: "Diff",
      comment_token: "# ",
      extensions: ["diff", "patch"],
      icon: "\u{F1492}",
      icon_color: 0x41535B,
      grammar: "diff"
    }
  end
end
