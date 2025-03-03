defmodule Banchan.Commissions do
  @moduledoc """
  The Commissions context.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Banchan.Repo

  alias Banchan.Accounts.User

  alias Banchan.Commissions.{
    Commission,
    CommissionArchived,
    CommissionFilter,
    Event,
    EventAttachment,
    Invoice,
    LineItem,
    Notifications
  }

  alias Banchan.Offerings
  alias Banchan.Offerings.{Offering, OfferingOption}
  alias Banchan.Studios
  alias Banchan.Studios.Studio
  alias Banchan.Uploads

  @pubsub Banchan.PubSub

  def list_commission_data_for_dashboard(
        %User{} = user,
        %CommissionFilter{} = filter,
        page,
        page_size \\ 10
      ) do
    main_dashboard_query(user)
    |> dashboard_query_filter(filter)
    |> Repo.paginate(page: page, page_size: page_size)
  end

  defp main_dashboard_query(%User{} = user) do
    from s in Studio,
      join: c in Commission,
      on: c.studio_id == s.id,
      join: artist in assoc(s, :artists),
      left_join: a in CommissionArchived,
      on: a.commission_id == c.id and a.user_id == ^user.id,
      join: client in assoc(c, :client),
      join: e in assoc(c, :events),
      where:
        c.client_id == ^user.id or
          artist.id == ^user.id,
      group_by: [c.id, s.id, client.id, client.handle, s.handle, s.name, a.archived],
      order_by: {:desc, max(e.inserted_at)},
      select: %{
        commission: %Commission{
          id: c.id,
          title: c.title,
          status: c.status,
          public_id: c.public_id,
          inserted_at: c.inserted_at
        },
        client: %User{
          id: client.id,
          name: client.name,
          handle: client.handle,
          pfp_thumb_id: client.pfp_thumb_id
        },
        studio: %Studio{
          id: s.id,
          handle: s.handle,
          name: s.name
        },
        archived: coalesce(a.archived, false),
        updated_at: max(e.inserted_at)
      }
  end

  defp dashboard_query_filter(query, %CommissionFilter{} = filter) do
    query
    |> filter_search(filter)
    |> filter_client(filter)
    |> filter_studio(filter)
    |> filter_statuses(filter)
    |> filter_show_archived(filter)
  end

  defp filter_search(query, %CommissionFilter{} = filter) do
    if is_nil(filter.search) || filter.search == "" do
      query
    else
      query
      |> where(
        [s, c, artist, archived, client, e],
        fragment("? @@ websearch_to_tsquery('banchan_fts', ?)", c.search_vector, ^filter.search) or
          fragment("? @@ websearch_to_tsquery('banchan_fts', ?)", e.search_vector, ^filter.search)
      )
    end
  end

  defp filter_client(query, %CommissionFilter{} = filter) do
    if is_nil(filter.client) || filter.client == "" do
      query
    else
      query
      |> where(
        [s, c, artist, archived, client, e],
        fragment(
          "? @@ websearch_to_tsquery('banchan_fts', ?)",
          client.search_vector,
          ^filter.client
        )
      )
    end
  end

  defp filter_studio(query, %CommissionFilter{} = filter) do
    if is_nil(filter.studio) || filter.studio == "" do
      query
    else
      query
      |> where(
        [s, c, artist, archived, client, e],
        fragment("? @@ websearch_to_tsquery('banchan_fts', ?)", s.search_vector, ^filter.studio)
      )
    end
  end

  defp filter_statuses(query, %CommissionFilter{} = filter) do
    if is_nil(filter.statuses) || Enum.empty?(filter.statuses) do
      query
    else
      query
      |> where([s, c, artist, archived, client, e], c.status in ^filter.statuses)
    end
  end

  defp filter_show_archived(query, %CommissionFilter{} = filter) do
    if filter.show_archived do
      query
    else
      query
      |> where([s, c, artist, archived, client, e], not coalesce(archived.archived, false))
    end
  end

  @doc """
  Gets a single commission for a studio.

  Raises `Ecto.NoResultsError` if the Commission does not exist.
  """
  def get_commission!(public_id, current_user) do
    Repo.one!(
      from c in Commission,
        join: s in assoc(c, :studio),
        join: artist in assoc(s, :artists),
        where:
          c.public_id == ^public_id and
            (c.client_id == ^current_user.id or
               ^current_user.id == artist.id),
        preload: [
          events: [:actor, invoice: [], attachments: [:upload, :thumbnail]],
          line_items: [:option],
          offering: [:options]
        ]
    )
  end

  # TODO: maybe this is too wide a net? We can separate this into user-level
  # and studio-level subscriptions, though it will mean multiple calls to
  # these subscription functions.
  def subscribe_to_new_commissions do
    Phoenix.PubSub.subscribe(@pubsub, "commission")
  end

  def unsubscribe_from_new_commissions do
    Phoenix.PubSub.unsubscribe(@pubsub, "commission")
  end

  def subscribe_to_commission_events(%Commission{public_id: public_id}) do
    Phoenix.PubSub.subscribe(@pubsub, "commission:#{public_id}")
  end

  def unsubscribe_from_commission_events(%Commission{public_id: public_id}) do
    Phoenix.PubSub.unsubscribe(@pubsub, "commission:#{public_id}")
  end

  @doc """
  Creates a commission.

  ## Examples

      iex> create_commission(actor, studio, offering, %{field: value})
      {:ok, %Commission{}}

      iex> create_commission(actor, studio, offering, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_commission(
        %User{} = actor,
        %Studio{} = studio,
        %Offering{} = offering,
        line_items,
        attachments,
        attrs \\ %{}
      ) do
    {:ok, ret} =
      Repo.transaction(fn ->
        offering = offering |> Repo.reload()
        available_proposal_count = Offerings.offering_available_proposals(offering)

        maybe_close_offering(offering, available_proposal_count)

        cond do
          !offering.open ->
            {:error, :offering_closed}

          is_nil(actor.confirmed_at) ->
            {:error, :not_confirmed}

          !is_nil(available_proposal_count) && available_proposal_count <= 0 ->
            {:error, :no_proposals_available}

          true ->
            insert_commission(actor, studio, offering, line_items, attachments, attrs)
        end
      end)

    ret
  end

  defp maybe_close_offering(offering, available_proposal_count) do
    # Make sure we close the offering if we're out of proposals.
    close = !is_nil(available_proposal_count) && available_proposal_count <= 1

    if close do
      # NB(zkat): We pretend we're a studio member here because we're doing
      # this on behalf of the studio. It's safe.
      {:ok, _} = Offerings.update_offering(offering, true, %{open: false})
    end
  end

  defp insert_commission(actor, studio, offering, line_items, attachments, attrs) do
    case %Commission{
           studio: studio,
           offering: offering,
           client: actor,
           line_items: line_items,
           events: [
             %{
               actor: actor,
               type: :comment,
               text: Map.get(attrs, "description", ""),
               attachments: attachments
             }
           ]
         }
         |> Commission.creation_changeset(attrs)
         |> Repo.insert() do
      {:ok, %Commission{} = commission} ->
        Notifications.subscribe_user!(actor, commission)
        Notifications.new_commission(commission, actor)
        {:ok, commission}

      {:error, err} ->
        {:error, err}
    end
  end

  def archived?(%User{} = user, %Commission{} = commission) do
    from(archived in CommissionArchived,
      where:
        archived.user_id == ^user.id and archived.commission_id == ^commission.id and
          archived.archived != false
    )
    |> Repo.exists?()
  end

  def update_archived(%User{} = actor, %Commission{} = commission, archived?) do
    %CommissionArchived{user: actor, commission: commission, archived: archived?}
    |> Repo.insert(
      on_conflict: {:replace, [:archived]},
      conflict_target: [:user_id, :commission_id]
    )
  end

  def update_status(%User{} = actor, %Commission{} = commission, status) do
    {:ok, ret} =
      Repo.transaction(fn ->
        changeset = Repo.reload!(commission) |> Commission.status_changeset(%{status: status})

        check_status_transition!(actor, commission, changeset.changes.status)

        {:ok, commission} = changeset |> Repo.update()

        if commission.status == :accepted do
          offering = Repo.preload(commission, :offering).offering
          available_slot_count = Offerings.offering_available_slots(offering)

          # Make sure we close the offering if we're out of slots.
          close = !is_nil(available_slot_count) && available_slot_count <= 1

          if close do
            # NB(zkat): We pretend we're a studio member here because we're doing
            # this on behalf of the studio. It's safe.
            {:ok, _} = Offerings.update_offering(offering, true, %{open: false})
          end
        end

        if commission.status == :approved do
          # Release any successful deposits.
          from(i in Invoice,
            where: i.commission_id == ^commission.id and i.status == :succeeded
          )
          |> Repo.update_all(set: [status: :released])

          from(e in Event,
            join: i in assoc(e, :invoice),
            where: i.commission_id == ^commission.id and i.status == :released,
            select: e,
            preload: [:actor, invoice: [], attachments: [:upload, :thumbnail]]
          )
          |> Repo.all()
          |> Enum.each(fn ev ->
            Notifications.commission_event_updated(commission, ev, actor)
          end)
        end

        # current_user_member? is checked as part of check_status_transition!
        {:ok, event} = create_event(:status, actor, commission, true, [], %{status: status})

        Notifications.commission_status_changed(commission, actor)

        {:ok, {commission, [event]}}
      end)

    ret
  end

  def release_payment!(%User{} = actor, %Commission{} = commission, %Invoice{} = invoice) do
    {1, _} =
      from(i in Invoice,
        join: c in assoc(i, :commission),
        where: i.id == ^invoice.id and c.client_id == ^actor.id and i.status == :succeeded
      )
      |> Repo.update_all(set: [status: :released])

    ev =
      from(e in Event,
        where: e.id == ^invoice.event_id,
        select: e,
        preload: [:actor, invoice: [], attachments: [:upload, :thumbnail]]
      )
      |> Repo.one!()

    Notifications.invoice_released(commission, ev, actor)
    Notifications.commission_event_updated(commission, ev, actor)

    :ok
  end

  defp check_status_transition!(
         %User{} = actor,
         %Commission{client_id: client_id, studio_id: studio_id, status: current_status},
         new_status
       ) do
    {:ok, _} =
      Repo.transaction(fn ->
        actor_member? = Studios.is_user_in_studio?(actor, %Studio{id: studio_id})

        true =
          status_transition_allowed?(
            actor_member?,
            client_id == actor.id,
            current_status,
            new_status
          )
      end)

    :ok
  end

  # Transition changes studios can make
  defp status_transition_allowed?(artist?, client?, from, to)

  defp status_transition_allowed?(true, _, :submitted, :accepted), do: true
  defp status_transition_allowed?(true, _, :submitted, :rejected), do: true
  defp status_transition_allowed?(true, _, :accepted, :in_progress), do: true
  defp status_transition_allowed?(true, _, :accepted, :ready_for_review), do: true
  defp status_transition_allowed?(true, _, :in_progress, :paused), do: true
  defp status_transition_allowed?(true, _, :in_progress, :waiting), do: true
  defp status_transition_allowed?(true, _, :in_progress, :ready_for_review), do: true
  defp status_transition_allowed?(true, _, :paused, :in_progress), do: true
  defp status_transition_allowed?(true, _, :waiting, :in_progress), do: true
  defp status_transition_allowed?(true, _, :ready_for_review, :in_progress), do: true
  defp status_transition_allowed?(true, _, :approved, :accepted), do: true
  defp status_transition_allowed?(true, _, :withdrawn, :accepted), do: true
  defp status_transition_allowed?(true, _, :rejected, :accepted), do: true

  # Transition changes clients can make
  defp status_transition_allowed?(_, true, :ready_for_review, :approved), do: true
  defp status_transition_allowed?(_, true, :withdrawn, :submitted), do: true

  # Either party can withdraw a commission (reimbursing the client)
  defp status_transition_allowed?(_, _, _, :withdrawn), do: true

  # Everything else is a no from me, Bob.
  defp status_transition_allowed?(_, _, _, _), do: false

  def commission_open?(%Commission{status: :withdrawn}), do: false
  def commission_open?(%Commission{status: :rejected}), do: false
  def commission_open?(%Commission{status: :approved}), do: false
  def commission_open?(%Commission{}), do: true

  def add_line_item(_, _, _, false) do
    {:error, :not_studio_member}
  end

  def add_line_item(%User{} = actor, %Commission{} = commission, option, true) do
    {:ok, ret} =
      Repo.transaction(fn ->
        line_item =
          case option do
            %OfferingOption{} ->
              %LineItem{
                option: option,
                amount: option.price || Money.new(0, :USD),
                name: option.name,
                description: option.description
              }

            %{amount: amount, name: name, description: description} ->
              %LineItem{
                amount: amount,
                name: name,
                description: description
              }
          end

        case commission
             |> Commission.update_changeset()
             |> Ecto.Changeset.put_assoc(:line_items, commission.line_items ++ [line_item])
             |> Repo.update() do
          {:error, err} ->
            {:error, err}

          {:ok, commission} ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case create_event(:line_item_added, actor, commission, true, [], %{
                   amount: line_item.amount,
                   text: line_item.name
                 }) do
              {:error, err} ->
                {:error, err}

              {:ok, event} ->
                Notifications.commission_line_items_changed(commission, actor)
                {:ok, {commission, [event]}}
            end
        end
      end)

    ret
  end

  def remove_line_item(_, _, _, false) do
    {:error, :not_studio_member}
  end

  def remove_line_item(%User{} = actor, %Commission{} = commission, line_item, true) do
    {:ok, ret} =
      Repo.transaction(fn ->
        line_items = Enum.filter(commission.line_items, &(&1.id != line_item.id))

        case commission
             |> Commission.update_changeset()
             |> Ecto.Changeset.put_assoc(:line_items, line_items)
             |> Repo.update() do
          {:error, err} ->
            {:error, err}

          {:ok, commission} ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            case create_event(:line_item_removed, actor, commission, true, [], %{
                   amount: line_item.amount,
                   text: line_item.name
                 }) do
              {:error, err} ->
                {:error, err}

              {:ok, event} ->
                Notifications.commission_line_items_changed(commission, actor)
                {:ok, {commission, [event]}}
            end
        end
      end)

    ret
  end

  @doc """
  Creates a event.
  """
  def create_event(type, actor, commission, current_user_member?, attachments, attrs)

  def create_event(
        _type,
        %User{id: user_id},
        %Commission{client_id: client_id},
        current_user_member?,
        _,
        _attrs
      )
      when user_id != client_id and current_user_member? == false do
    {:error, :unauthorized}
  end

  def create_event(
        type,
        %User{} = actor,
        %Commission{} = commission,
        _current_user_member?,
        attachments,
        attrs
      )
      when is_atom(type) do
    ret =
      %Event{
        type: type,
        commission: commission,
        actor: actor,
        attachments: attachments
      }
      |> Event.changeset(attrs)
      |> Repo.insert()

    case ret do
      {:ok, event} ->
        Notifications.new_commission_events(commission, [%{event | invoice: nil}], actor)

      _ ->
        nil
    end

    ret
  end

  @doc """
  Updates a event.

  ## Examples

      iex> update_event(event, %{field: new_value})
      {:ok, %Event{}}

      iex> update_event(event, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_event(%Event{} = event, attrs) do
    event
    |> Event.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a event.

  ## Examples

      iex> delete_event(event)
      {:ok, %Event{}}

      iex> delete_event(event)
      {:error, %Ecto.Changeset{}}

  """
  def delete_event(%Event{} = event) do
    Repo.delete(event)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking event changes.

  ## Examples

      iex> change_event(event)
      %Ecto.Changeset{data: %Event{}}

  """
  def change_event(%Event{} = event, attrs \\ %{}) do
    Event.changeset(event, attrs)
  end

  def change_event_text(%Event{} = event, attrs \\ %{}) do
    Event.text_changeset(event, attrs)
  end

  def send_event_update!(event_id, actor \\ nil) do
    event =
      from(e in Event,
        where: e.id == ^event_id,
        select: e,
        preload: [:actor, invoice: [], attachments: [:upload, :thumbnail]]
      )
      |> Repo.one!()

    commission =
      from(c in Commission, where: c.id == ^event.commission_id)
      |> Repo.one!()

    Notifications.commission_event_updated(commission, event, actor)
  end

  # This one expects binaries for everything because it looks everything up in one fell swoop.
  def get_attachment_if_allowed!(commission, key, user) do
    Repo.one!(
      from ea in EventAttachment,
        join: ul in assoc(ea, :upload),
        join: e in assoc(ea, :event),
        join: c in assoc(e, :commission),
        join: s in assoc(c, :studio),
        join: artist in assoc(s, :artists),
        select: ea,
        where:
          c.public_id == ^commission and
            ul.key == ^key and
            (c.client_id == ^user.id or artist.id == ^user.id),
        preload: [:upload, :thumbnail]
    )
  end

  def make_attachment!(%User{} = user, src, type, name) do
    upload = Uploads.save_file!(user, src, type, name)

    thumbnail =
      if Uploads.image?(upload) || Uploads.video?(upload) do
        # SECURITY: No fs traversal here because Path.extname(name) is safe. We do need that extension, tho.
        tmp_file = Path.join([System.tmp_dir!(), upload.key <> Path.extname(name)])
        File.mkdir_p!(Path.dirname(tmp_file))
        File.rename(src, tmp_file)

        # SECURITY: If someone uploads an .exe as a media type, this will crash, so we're safe :)
        mog =
          Mogrify.open(tmp_file)
          |> Mogrify.format("jpeg")
          |> Mogrify.gravity("Center")
          |> Mogrify.resize_to_fill("128x128")
          |> Mogrify.save()

        final_path =
          if Uploads.video?(upload) do
            mog.path |> String.replace(~r/\.jpeg$/, "-0.jpeg")
          else
            mog.path
          end

        thumb = Uploads.save_file!(user, final_path, "image/jpeg", "thumbnail.jpg")
        File.rm!(tmp_file)
        File.rm!(final_path)

        thumb
      end

    %EventAttachment{
      upload: upload,
      thumbnail: thumbnail
    }
  end

  def delete_attachment!(
        %User{} = actor,
        %Commission{} = commission,
        %Event{} = event,
        %EventAttachment{} = event_attachment
      ) do
    # NOTE: This also deletes any associated uploads, because of the db ON DELETE
    Repo.delete!(event_attachment)
    new_attachments = Enum.reject(event.attachments, &(&1.id == event_attachment.id))

    Notifications.commission_event_updated(
      commission,
      %{event | attachments: new_attachments},
      actor
    )
  end

  def add_comment(
        %User{} = actor,
        %Commission{} = commission,
        current_user_member?,
        attachments,
        text
      ) do
    create_event(
      :comment,
      actor,
      commission,
      current_user_member?,
      attachments,
      %{"text" => text}
    )
  end

  def invoice_paid?(%Invoice{status: status}), do: status == :succeeded

  def invoice(_actor, _commission, false, _drafts, _event_data) do
    {:error, :unauthorized}
  end

  def invoice(%User{} = actor, %Commission{} = commission, true, drafts, event_data) do
    {:ok, ret} =
      Repo.transaction(fn ->
        case create_event(:comment, actor, commission, true, drafts, event_data) do
          {:error, error} ->
            {:error, error}

          {:ok, event} ->
            case %Invoice{
                   client_id: commission.client_id,
                   commission: commission,
                   event: event
                 }
                 |> Invoice.creation_changeset(event_data)
                 |> Repo.insert() do
              {:error, error} ->
                {:error, error}

              {:ok, invoice} ->
                send_event_update!(event.id, actor)
                {:ok, invoice}
            end
        end
      end)

    ret
  end

  def process_payment!(%User{id: user_id}, _, %Commission{client_id: client_id}, _, _)
      when user_id != client_id do
    {:error, :unauthorized}
  end

  def process_payment!(
        %User{} = actor,
        %Event{invoice: %Invoice{amount: amount} = invoice} = event,
        %Commission{} = commission,
        uri,
        tip
      ) do
    items = [
      %{
        name: "Commission Invoice Payment",
        quantity: 1,
        amount: amount.amount,
        currency: String.downcase(to_string(amount.currency))
      },
      %{
        name: "Extra Tip",
        quantity: 1,
        amount: tip.amount,
        currency: String.downcase(to_string(tip.currency))
      }
    ]

    {stripe_id, platform_fee} =
      from(studio in Studio,
        where: studio.id == ^commission.studio_id,
        select: {studio.stripe_id, studio.platform_fee}
      )
      |> Repo.one!()

    platform_fee = Money.multiply(Money.add(amount, tip), platform_fee)

    {:ok, session} =
      stripe_mod().create_session(%{
        payment_method_types: ["card"],
        mode: "payment",
        cancel_url: uri,
        success_url: uri,
        line_items: items,
        payment_intent_data: %{
          application_fee_amount: platform_fee.amount,
          transfer_data: %{
            destination: stripe_id
          }
        }
      })

    invoice
    |> Invoice.submit_changeset(%{
      tip: tip,
      platform_fee: platform_fee,
      stripe_session_id: session.id,
      checkout_url: session.url,
      status: :submitted
    })
    |> Repo.update!()

    send_event_update!(event.id, actor)

    session.url
  end

  def process_payment_succeeded!(session) do
    {:ok, %{charges: %{data: [%{balance_transaction: txn_id}]}}} =
      stripe_mod().retrieve_payment_intent(session.payment_intent, %{}, [])

    {:ok, %{available_on: available_on, amount: amt, currency: curr}} =
      stripe_mod().retrieve_balance_transaction(txn_id, [])

    amount = Money.new(amt, String.to_atom(String.upcase(curr)))

    {:ok, available_on} = DateTime.from_unix(available_on)

    {:ok, _} =
      Repo.transaction(fn ->
        {1, [invoice]} =
          from(i in Invoice, where: i.stripe_session_id == ^session.id, select: i)
          |> Repo.update_all(
            set: [
              status: :succeeded,
              payout_available_on: available_on
            ]
          )

        event = Repo.get!(Event, invoice.event_id)

        create_event(
          :payment_processed,
          Repo.reload!(%User{id: event.actor_id}),
          Repo.reload!(%Commission{id: event.commission_id}),
          true,
          [],
          %{
            amount: amount
          }
        )

        send_event_update!(invoice.event_id)
      end)

    :ok
  end

  def process_payment_expired!(session) do
    # NOTE: This will crash (intentionally) if we try to expire an
    # already-succeeded payment. This should never happen, though, because it
    # doesn't make sense that Stripe would tell us that a payment succeeded
    # then tell us it's expired. So this crash is a good just-in-case.
    {1, [invoice]} =
      from(i in Invoice,
        where: i.stripe_session_id == ^session.id and i.status != :succeeded,
        select: i
      )
      |> Repo.update_all(set: [status: :expired])

    send_event_update!(invoice.event_id)
  end

  def expire_payment!(invoice, current_user_member?)

  def expire_payment!(_, false) do
    {:error, :unauthorized}
  end

  def expire_payment!(%Invoice{id: id, stripe_session_id: nil, status: :pending}, _) do
    # NOTE: This will crash (intentionally) if we try to expire an already-succeeded payment.
    {1, [invoice]} =
      from(i in Invoice, where: i.id == ^id and i.status != :succeeded, select: i)
      |> Repo.update_all(set: [status: :expired])

    send_event_update!(invoice.event_id)
    :ok
  end

  def expire_payment!(%Invoice{stripe_session_id: session_id, status: :submitted}, _)
      when session_id != nil do
    # NOTE: We don't manually expire the invoice in the database here. That's
    # handled by process_payment_expired!/1 when the webhook fires.
    :ok = stripe_mod().expire_payment(session_id)
  end

  def expire_payment!(%Invoice{}, _) do
    raise "Tried to expire an invoice in an invalid state. Reload the invoice and try again. Otherwise, this is a bug."
  end

  def refund_payment(actor, invoice, current_user_member?)

  def refund_payment(_, _, false) do
    {:error, :unauthorized}
  end

  def refund_payment(%User{} = actor, %Invoice{} = invoice, _) do
    {:ok, ret} =
      Repo.transaction(fn ->
        invoice = invoice |> Repo.reload()

        if invoice.status != :succeeded do
          Logger.error(%{
            message: "Attempted to refund an invoice that wasn't :succeeded.",
            invoice: invoice
          })

          {:error, :invoice_not_refundable}
        else
          process_refund_payment(actor, invoice)
        end
      end)

    ret
  end

  defp process_refund_payment(%User{} = actor, %Invoice{} = invoice) do
    case refund_payment_on_stripe(invoice) do
      {:ok, %Stripe.Refund{status: "failed"} = refund} ->
        Logger.error(%{message: "Refund failed", refund: refund})
        process_refund_updated(refund, invoice.id, actor)

      {:ok, %Stripe.Refund{status: "canceled"} = refund} ->
        Logger.error(%{message: "Refund canceled", refund: refund})
        process_refund_updated(refund, invoice.id, actor)

      {:ok, %Stripe.Refund{status: "requires_action"} = refund} ->
        Logger.info(%{message: "Refund requires action", refund: refund})
        # This should eventually succeed asynchronously.
        process_refund_updated(refund, invoice.id, actor)

      {:ok, %Stripe.Refund{status: "succeeded"} = refund} ->
        process_refund_updated(refund, invoice.id, actor)

      {:ok, %Stripe.Refund{status: "pending"} = refund} ->
        process_refund_updated(refund, invoice.id, actor)

      {:error, %Stripe.Error{} = err} ->
        {:error, err}
    end
  end

  defp refund_payment_on_stripe(%Invoice{} = invoice) do
    case stripe_mod().retrieve_session(invoice.stripe_session_id, []) do
      {:ok, session} ->
        case stripe_mod().retrieve_payment_intent(session.payment_intent, %{}, []) do
          {:ok, %Stripe.PaymentIntent{charges: %{data: [%{id: charge_id}]}}} ->
            # https://stripe.com/docs/connect/destination-charges#issuing-refunds
            case stripe_mod().create_refund(
                   %{
                     charge: charge_id,
                     reverse_transfer: true,
                     refund_application_fee: true
                   },
                   []
                 ) do
              {:ok, refund} ->
                {:ok, refund}

              {:error, err} ->
                Logger.error(%{message: "Refund failed.", error: err})
                {:error, err}
            end

          {:error, err} ->
            Logger.error(%{
              message: "Failed to retrieve payment intent while refunding.",
              error: err
            })

            {:error, err}
        end

      {:error, err} ->
        Logger.error(%{message: "Failed to retrieve session while refunding.", error: err})
        {:error, err}
    end
  end

  # Disabling because honestly, refactoring this one is pointless.
  #
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def process_refund_updated(%Stripe.Refund{} = refund, invoice_id, actor \\ nil) do
    {:ok, ret} =
      Repo.transaction(fn ->
        assignments =
          case refund.status do
            "succeeded" ->
              [
                status: :refunded,
                refund_status: :succeeded,
                stripe_refund_id: refund.id,
                refund_failure_reason: nil
              ]

            "failed" ->
              [
                refund_status: :failed,
                stripe_refund_id: refund.id,
                refund_failure_reason: refund.failure_reason
              ]

            "canceled" ->
              [refund_status: :canceled, stripe_refund_id: refund.id, refund_failure_reason: nil]

            "pending" ->
              [refund_status: :pending, stripe_refund_id: refund.id, refund_failure_reason: nil]

            "requires_action" ->
              [
                refund_status: :requires_action,
                stripe_refund_id: refund.id,
                refund_failure_reason: nil
              ]
          end

        assignments =
          if is_nil(actor) do
            assignments
          else
            assignments ++ [refunded_by_id: actor.id]
          end

        update_res =
          if is_nil(invoice_id) do
            from(i in Invoice,
              where: i.status == :succeeded and i.stripe_refund_id == ^refund.id,
              select: i.id
            )
          else
            from(i in Invoice, where: i.status == :succeeded and i.id == ^invoice_id, select: i.id)
          end
          |> Repo.update_all(set: assignments)

        case update_res do
          {1, [invoice_id]} ->
            case from(e in Event,
                   join: i in assoc(e, :invoice),
                   where: i.id == ^invoice_id,
                   select: e,
                   preload: [:actor, :commission, invoice: [], attachments: [:upload, :thumbnail]]
                 )
                 |> Repo.one() do
              %Event{} = ev -> {:ok, ev}
              nil -> {:error, :event_not_found}
            end

          {0, _} ->
            {:error, :invoice_not_found}
        end
      end)

    case ret do
      {:ok, event} ->
        Notifications.invoice_refund_updated(event.commission, event, actor)
        Notifications.commission_event_updated(event.commission, event, actor)
        {:ok, event.invoice}

      {:error, err} ->
        Logger.error(%{message: "Failed to update invoice status to refunded", error: err})
        {:error, :internal_error}
    end
  end

  def deposited_amount(
        %User{id: user_id},
        %Commission{client_id: client_id},
        current_user_member?
      )
      when user_id != client_id and current_user_member? == false do
    {:error, :unauthorized}
  end

  def deposited_amount(_, %Commission{} = commission, _) do
    if Ecto.assoc_loaded?(commission.events) do
      Enum.reduce(
        commission.events,
        # TODO: Using :USD here is a bad idea for later, but idk how to do it better yet.
        Money.new(0, :USD),
        fn event, acc ->
          if event.invoice && event.invoice.status in [:succeeded, :released] do
            Money.add(acc, event.invoice.amount)
          else
            acc
          end
        end
      )
    else
      deposits =
        from(
          i in Invoice,
          where:
            i.commission_id == ^commission.id and
              i.status == :succeeded,
          select: i.amount
        )
        |> Repo.all()

      Enum.reduce(
        deposits,
        # TODO: Using :USD here is a bad idea for later, but idk how to do it better yet.
        Money.new(0, :USD),
        fn dep, acc -> Money.add(acc, dep.amount) end
      )
    end
  end

  def latest_draft(%User{id: user_id}, %Commission{client_id: client_id}, current_user_member?)
      when user_id != client_id and current_user_member? == false do
    {:error, :unauthorized}
  end

  def latest_draft(_, %Commission{} = commission, _) do
    case from(
           e in Event,
           join: us in "users_studios",
           join: c in Commission,
           join: ea in EventAttachment,
           where:
             e.type == :comment and
               c.id == ^commission.id and
               e.commission_id == c.id and
               us.studio_id == c.studio_id and
               e.actor_id == us.user_id and
               ea.event_id == e.id,
           select: e,
           limit: 1,
           order_by: {:desc, e.inserted_at},
           preload: [attachments: [:upload, :thumbnail]]
         )
         |> Repo.all() do
      [] -> nil
      [event] -> event
    end
  end

  defp stripe_mod do
    Application.get_env(:banchan, :stripe_mod)
  end
end
