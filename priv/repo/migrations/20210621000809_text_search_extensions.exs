defmodule Banchan.Repo.Migrations.TextSearchExtensions do
  use Ecto.Migration

  def up do
    execute """
    CREATE EXTENSION unaccent;
    """

    execute """
    CREATE EXTENSION pg_trgm;
    """

    execute """
    CREATE TEXT SEARCH CONFIGURATION banchan_fts ( COPY = english );
    """

    execute """
    ALTER TEXT SEARCH CONFIGURATION banchan_fts
      ALTER MAPPING FOR hword, hword_part, word
      WITH unaccent, simple;
    """
  end

  def down do
    execute """
    DROP EXTENSION unaccent;
    """

    execute """
    DROP EXTENSION pg_trgm;
    """

    execute """
    DROP TEXT SEARCH CONFIGURATION banchan_fts;
    """
  end
end