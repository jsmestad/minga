defmodule Minga.Language.Erlang do
  @moduledoc "Erlang language definition"

  alias Minga.Language
  alias Minga.LSP.ServerConfig

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :erlang,
      label: "Erlang",
      comment_token: "% ",
      extensions: ["erl", "hrl"],
      filenames: ["rebar.config", "rebar.lock"],
      shebangs: ["escript"],
      icon: "\u{E7B1}",
      icon_color: 0xA90533,
      grammar: "erlang",
      language_servers: [
        %ServerConfig{
          name: :erlang_ls,
          command: "erlang_ls",
          root_markers: ["rebar.config", "erlang.mk"]
        }
      ],
      root_markers: ["rebar.config"]
    }
  end
end
