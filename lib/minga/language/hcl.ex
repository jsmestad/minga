defmodule Minga.Language.Hcl do
  @moduledoc "HCL language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :hcl,
      label: "HCL",
      comment_token: "// ",
      extensions: ["tf", "tfvars", "hcl"],
      icon: "\u{F1062}",
      icon_color: 0x7B42BC,
      grammar: "hcl"
    }
  end
end
