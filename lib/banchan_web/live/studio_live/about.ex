defmodule BanchanWeb.StudioLive.About do
  @moduledoc """
  LiveView for viewing individual Studios
  """
  use BanchanWeb, :surface_view

  alias BanchanWeb.Components.Markdown

  import BanchanWeb.StudioLive.Helpers

  alias BanchanWeb.StudioLive.Components.StudioLayout

  @impl true
  def mount(params, _session, socket) do
    socket = assign_studio_defaults(params, socket, false, false)
    {:ok, socket}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, socket |> assign(uri: uri)}
  end

  @impl true
  def render(assigns) do
    ~F"""
    <StudioLayout
      id="studio-layout"
      current_user={@current_user}
      flashes={@flash}
      studio={@studio}
      current_user_member?={@current_user_member?}
      tab={:about}
      uri={@uri}
    >
      <Markdown content={@studio.summary} />
    </StudioLayout>
    """
  end
end
