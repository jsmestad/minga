defmodule Minga.Language.EmacsLisp do
  @moduledoc "Emacs Lisp language definition"

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :emacs_lisp,
      label: "Emacs Lisp",
      comment_token: ";; ",
      extensions: ["el"],
      icon: "\u{E632}",
      icon_color: 0x7F5AB6,
      grammar: "elisp"
    }
  end
end
