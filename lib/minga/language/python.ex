defmodule Minga.Language.Python do
  @moduledoc "Python language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :python,
      label: "Python",
      comment_token: "# ",
      extensions: ["py", "pyi"],
      shebangs: ["python", "python3"],
      icon: "\u{E73C}",
      icon_color: 0x3776AB,
      tab_width: 4,
      grammar: "python",
      formatter: "python3 -m black --quiet -",
      language_servers: [
        %ServerConfig{
          name: :pyright,
          command: "pyright-langserver",
          args: ["--stdio"],
          root_markers: ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"]
        }
      ],
      root_markers: ["pyproject.toml", "setup.py"],
      project_type: :python
    }
  end
end
