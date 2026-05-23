defmodule Minga.Test.Fixtures.LanguagePacks.DuplicateExtensionPack.FirstLanguage do
  @moduledoc false

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :language_pack_duplicate_extension_ok,
      label: "Language Pack Duplicate Extension Ok",
      comment_token: "# ",
      extensions: ["language_pack_duplicate_extension"]
    }
  end
end
