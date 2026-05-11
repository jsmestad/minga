defmodule Minga.Language.Hcl do
  @moduledoc "HCL language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :hcl,
      label: "HCL",
      comment_token: "// ",
      extensions: ["tf", "tfvars", "hcl"],
      icon: "\u{F1062}",
      icon_color: 0x7B42BC,
      grammar: "hcl",
      language_servers: [
        %ServerConfig{
          name: :terraform_ls,
          command: "terraform-ls",
          args: ["serve"],
          root_markers: ["main.tf", "*.tf"]
        }
      ],
      root_markers: ["main.tf"]
    }
  end
end
