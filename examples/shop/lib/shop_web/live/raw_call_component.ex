defmodule ShopWeb.RawCallComponent do
  @moduledoc """
  A raw call to Stripe, for what Mishka Pay has no typed call for yet (`MishkaPay.request/1`):
  a read of any API path with the site's keys, with another API version and the objects to
  expand for this call only, answered as Stripe's own JSON. A path that is not a plain API path
  (`//evil.test`, `https://evil.test/x`, `../`) is refused before anything is sent.

  Nothing is read until "Send" is pressed; the answer is read in the background
  (`start_async`), with a loading mark while Stripe answers. A refusal shows inside the part's
  own card and goes when the form is changed or sent again.
  """

  use ShopWeb, :live_component

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       form: %{"path" => "/v1/balance", "expand" => "", "api_version" => ""},
       reading?: false,
       answer: nil,
       error: nil
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("edit", params, socket),
    do: {:noreply, assign(socket, form: params, error: nil)}

  def handle_event("send", params, socket) do
    attrs = %{
      provider: "stripe",
      tenant: socket.assigns.tenant,
      path: String.trim(params["path"] || ""),
      options: options(params)
    }

    {:noreply,
     socket
     |> assign(form: params, reading?: true, answer: nil, error: nil)
     |> start_async(:raw_call, fn -> MishkaPay.request(attrs) end)}
  end

  @impl true
  def handle_async(:raw_call, {:ok, {:ok, answer}}, socket),
    do: {:noreply, assign(socket, reading?: false, answer: Jason.encode!(answer, pretty: true))}

  def handle_async(:raw_call, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, reading?: false, error: MishkaPay.Ash.message(error))}

  def handle_async(:raw_call, {:exit, reason}, socket),
    do: {:noreply, assign(socket, reading?: false, error: inspect(reason))}

  # Only the options given: an empty field asks for nothing.
  defp options(params) do
    expand =
      params["expand"]
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{api_version: blank(params["api_version"]), expand: (expand != [] && expand) || nil}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp blank(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      text -> text
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="raw-call" class="space-y-4">
      <.section_title icon="hero-command-line" title="Raw call" />
      <p class="text-sm opacity-70">
        Any Stripe API path with this site's keys, for what Mishka Pay has no call for yet. Only
        a plain path from the root is sent; an address or a path with <code>..</code>
        is refused before anything leaves the shop.
      </p>
      <.hint>MishkaPay.request/1, MishkaPay.RawRequest.Options</.hint>

      <form
        id="raw-call-form"
        phx-change="edit"
        phx-submit="send"
        phx-target={@myself}
        class="card bg-base-200"
        data-testid="raw-call-form"
      >
        <div class="card-body gap-3">
          <div class="grid gap-3 sm:grid-cols-3">
            <label class="fieldset">
              <span class="fieldset-legend">Path (GET)</span>
              <input
                name="path"
                value={@form["path"]}
                placeholder="/v1/balance"
                class="input input-sm font-mono"
                data-testid="raw-call-path"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">Expand (comma separated)</span>
              <input
                name="expand"
                value={@form["expand"]}
                placeholder="data.customer"
                class="input input-sm font-mono"
                data-testid="raw-call-expand"
              />
            </label>
            <label class="fieldset">
              <span class="fieldset-legend">API version (this call only)</span>
              <input
                name="api_version"
                value={@form["api_version"]}
                placeholder="the pinned one"
                class="input input-sm font-mono"
                data-testid="raw-call-version"
              />
            </label>
          </div>
          <div>
            <button
              class="btn btn-sm btn-primary"
              disabled={@reading?}
              data-testid="raw-call-submit"
            >
              Send
            </button>
            <span
              :if={@reading?}
              class="loading loading-spinner loading-sm ml-2"
              data-testid="raw-call-reading"
            ></span>
          </div>
          <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="raw-call-error">
            {@error}
          </div>
        </div>
      </form>

      <pre
        :if={@answer}
        class="rounded-box bg-base-200 p-3 text-xs overflow-auto max-h-96"
        data-testid="raw-call-answer"
      >{@answer}</pre>
    </section>
    """
  end
end
