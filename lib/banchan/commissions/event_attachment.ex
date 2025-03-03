defmodule Banchan.Commissions.EventAttachment do
  @moduledoc """
  File/upload attachments for commission Events.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Banchan.Commissions.Event
  alias Banchan.Uploads.Upload

  schema "event_attachments" do
    belongs_to :event, Event
    belongs_to :upload, Upload, type: :binary_id
    belongs_to :thumbnail, Upload, type: :binary_id

    timestamps()
  end

  @doc false
  def changeset(event_attachment, attrs) do
    event_attachment
    |> cast(attrs, [])
    |> validate_required([])
  end
end
