defmodule Minga.Language.Perl do
  @moduledoc "Perl language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :perl,
      label: "Perl",
      comment_token: "# ",
      shebangs: ["perl"],
      icon: "\u{E769}",
      icon_color: 0x39457E
    }
  end
end
