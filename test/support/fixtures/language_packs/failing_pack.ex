defmodule Minga.Test.Fixtures.LanguagePacks.DuplicateExtensionPack do
  @moduledoc false

  @spec name() :: atom()
  def name, do: :language_pack_duplicate_extension_test

  @spec language_modules() :: [module()]
  def language_modules,
    do: [
      Minga.Test.Fixtures.LanguagePacks.DuplicateExtensionPack.FirstLanguage,
      Minga.Test.Fixtures.LanguagePacks.DuplicateExtensionPack.DuplicateLanguage
    ]
end
