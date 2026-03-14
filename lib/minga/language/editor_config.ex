defmodule Minga.Language.EditorConfig do
  @moduledoc "EditorConfig language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :editorconfig,
      label: "EditorConfig",
      comment_token: "# ",
      filenames: [".editorconfig"],
      icon: "\u{E615}",
      icon_color: 0x6D8086
    }
  end
end
