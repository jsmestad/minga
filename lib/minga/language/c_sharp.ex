defmodule Minga.Language.CSharp do
  @moduledoc "C# language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :c_sharp,
      label: "C#",
      comment_token: "// ",
      extensions: ["cs", "csx"],
      icon: "\u{F031B}",
      icon_color: 0x68217A,
      grammar: "c_sharp"
    }
  end
end
