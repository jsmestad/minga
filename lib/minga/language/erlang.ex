defmodule Minga.Language.Erlang do
  @moduledoc "Erlang language definition"

  alias Minga.Language

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
      grammar: "erlang"
    }
  end
end
