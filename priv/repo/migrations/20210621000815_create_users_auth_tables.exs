defmodule Banchan.Repo.Migrations.CreateUsersAuthTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:uploads, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string
      add :bucket, :string, null: false
      add :key, :string, null: false
      add :type, :string
      add :size, :integer, null: false

      timestamps()
    end

    create unique_index(:uploads, [:bucket, :key])

    create table(:users) do
      add :handle, :citext, null: false
      add :email, :citext, null: false
      add :hashed_password, :string, null: false
      add :confirmed_at, :naive_datetime
      add :roles, {:array, :string}, default: [], null: false
      add :name, :string
      add :bio, :string
      add :totp_secret, :binary
      add :totp_activated, :boolean
      add :header_img_id, references(:uploads, on_delete: :nilify_all, type: :uuid)
      add :pfp_img_id, references(:uploads, on_delete: :nilify_all, type: :uuid)
      add :pfp_thumb_id, references(:uploads, on_delete: :nilify_all, type: :uuid)
      timestamps()
    end

    execute(
      fn ->
        repo().query!(
          """
          ALTER TABLE users ADD COLUMN search_vector tsvector
            GENERATED ALWAYS AS (
              setweight(to_tsvector('banchan_fts', handle), 'A') ||
              setweight(to_tsvector('banchan_fts', coalesce(name, '')), 'B')
            ) STORED;
          """,
          [],
          log: :info
        )

        repo().query!(
          """
          CREATE INDEX users_search_idx ON users USING GIN (search_vector);
          """,
          [],
          log: :info
        )
      end,
      fn ->
        repo().query!(
          """
          DROP INDEX users_search_idx;
          """,
          [],
          log: :info
        )
      end
    )

    create unique_index(:users, [:email])
    create unique_index(:users, [:handle])

    create index(:users, [:header_img_id])
    create index(:users, [:pfp_img_id])
    create index(:users, [:pfp_thumb_id])

    alter table(:uploads) do
      add :uploader_id, references(:users, on_delete: :nilify_all)
    end

    create index(:uploads, [:uploader_id])

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      timestamps(updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
  end
end
