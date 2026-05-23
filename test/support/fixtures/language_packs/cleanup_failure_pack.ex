defmodule Minga.Test.Fixtures.LanguagePacks.CleanupFailurePack do
  @moduledoc false

  @spec name() :: atom()
  def name, do: :language_pack_cleanup_failure_test

  @spec language_modules() :: [module()]
  def language_modules,
    do: [
      Minga.Test.Fixtures.LanguagePacks.CleanupFailurePack.FirstLanguage,
      Minga.Test.Fixtures.LanguagePacks.CleanupFailurePack.CollisionLanguage
    ]
end
