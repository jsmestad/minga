defmodule Minga.Test.Fixtures.LanguagePacks.CleanupFailurePack.CollisionLanguage do
  @moduledoc false

  alias Minga.Language

  @spec definition() :: Language.t()
  def definition do
    %Language{
      name: :language_pack_cleanup_collision,
      label: "Language Pack Cleanup Collision",
      comment_token: "# ",
      extensions: ["language_pack_cleanup_collision"]
    }
  end
end
