defmodule Minga.Language.Lua do
  @moduledoc "Lua language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :lua,
      label: "Lua",
      comment_token: "-- ",
      extensions: ["lua"],
      shebangs: ["lua"],
      icon: "\u{E620}",
      icon_color: 0x000080,
      grammar: "lua",
      language_servers: [
        %ServerConfig{
          name: :lua_ls,
          command: "lua-language-server",
          root_markers: [".luarc.json", ".luarc.jsonc", ".stylua.toml"]
        }
      ]
    }
  end
end
