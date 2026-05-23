defmodule Minga.Test.Fixtures.LanguagePacks.FilenameFailingPack do
  @moduledoc false

  @spec name() :: atom()
  def name, do: :language_pack_filename_failure_test

  @spec language_modules() :: [module()]
  def language_modules,
    do: [
      Minga.Test.Fixtures.LanguagePacks.FilenameFailingPack.FirstLanguage,
      Minga.Test.Fixtures.LanguagePacks.FilenameFailingPack.DuplicateLanguage
    ]
end
