defmodule Minga.Language.Make do
  @moduledoc "Makefile language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :make,
      label: "Makefile",
      comment_token: "# ",
      extensions: ["mk", "mak"],
      filenames: ["Makefile", "GNUmakefile"],
      icon: "\u{E673}",
      icon_color: 0x6D8086,
      tab_width: 4,
      indent_with: :tabs,
      grammar: "make"
    }
  end
end
