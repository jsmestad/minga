defmodule Minga.Test.Fixtures.LanguagePacks.DuplicateExtensionPack.DuplicateLanguage do
  @moduledoc false

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :language_pack_duplicate_extension_duplicate,
      label: "Language Pack Duplicate Extension Duplicate",
      comment_token: "# ",
      extensions: ["language_pack_duplicate_extension"]
    }
  end
end
