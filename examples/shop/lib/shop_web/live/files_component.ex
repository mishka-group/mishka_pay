defmodule ShopWeb.FilesComponent do
  @moduledoc """
  Evidence files for disputes: upload a PNG, JPEG or PDF (LiveView uploads) to Stripe with
  `MishkaPay.upload_file/1` (purpose `:dispute_evidence`), show its id, size and a public link
  (`MishkaPay.file_link/4`), and attach it to an open dispute's evidence as its
  `uncategorized_file` (`Shop.Pay.Dispute` `:submit_evidence`, kept to add more, not sent).
  """

  use ShopWeb, :live_component

  require Ash.Query

  import ShopWeb.PayComponents, only: [section_title: 1, hint: 1]

  alias Shop.Pay.Dispute

  # Stripe takes dispute evidence as PDF, JPEG or PNG, up to 5 MB.
  @max_size 5_000_000

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(file: nil, link: nil, link_error: nil, disputes: [], notice: nil, error: nil)
     |> allow_upload(:evidence,
       accept: ~w(.png .jpg .jpeg .pdf),
       max_entries: 1,
       max_file_size: @max_size
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, tenant: assigns.tenant)}

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, assign(socket, error: nil)}

  def handle_event("cancel", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :evidence, ref)}

  def handle_event("upload", _params, socket) do
    tenant = socket.assigns.tenant

    uploaded =
      consume_uploaded_entries(socket, :evidence, fn %{path: path}, entry ->
        {:ok, upload(path, entry, tenant)}
      end)

    case uploaded do
      [] ->
        {:noreply, assign(socket, error: "Choose a PNG, JPEG or PDF first.", notice: nil)}

      [{:ok, file}] ->
        {:noreply,
         socket
         |> assign(file: file, notice: "Uploaded to Stripe: #{file.id}.", error: nil)
         |> assign(disputes: open_disputes(tenant))
         |> link(file)}

      [{:error, error}] ->
        {:noreply, assign(socket, error: MishkaPay.Ash.message(error), notice: nil)}
    end
  end

  def handle_event("attach", %{"dispute" => ""}, socket),
    do: {:noreply, assign(socket, error: "Choose a dispute to attach the file to.", notice: nil)}

  def handle_event("attach", %{"dispute" => id}, %{assigns: %{file: %{id: file_id}}} = socket) do
    args = %{evidence: %{"uncategorized_file" => file_id}, submit: false}

    id
    |> then(&Ash.get!(Dispute, &1, authorize?: false))
    |> Ash.Changeset.for_update(:submit_evidence, args)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, dispute} ->
        {:noreply,
         assign(socket,
           notice: "#{file_id} is now evidence of #{dispute.provider_id}, kept to add more.",
           error: nil
         )}

      {:error, error} ->
        {:noreply, assign(socket, error: MishkaPay.Ash.message(error), notice: nil)}
    end
  end

  def handle_event("attach", _params, socket),
    do: {:noreply, assign(socket, error: "Upload a file first.", notice: nil)}

  defp upload(path, entry, tenant) do
    MishkaPay.upload_file(%{
      provider: "stripe",
      tenant: tenant,
      purpose: :dispute_evidence,
      filename: entry.client_name,
      content_type: entry.client_type,
      content: File.read!(path)
    })
  end

  defp link(socket, file) do
    case MishkaPay.file_link("stripe", file.id, socket.assigns.tenant) do
      {:ok, link} -> assign(socket, link: link, link_error: nil)
      {:error, error} -> assign(socket, link: nil, link_error: MishkaPay.Ash.message(error))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section data-testid="files" class="space-y-4">
      <.section_title icon="hero-paper-clip" title="Evidence files" />
      <p class="text-sm opacity-70">
        A receipt or a screenshot that answers a dispute: upload it to Stripe, then attach it to a
        dispute's evidence. PNG, JPEG or PDF, up to 5 MB.
      </p>
      <.hint>MishkaPay.upload_file/1, MishkaPay.file_link/4, Shop.Pay.Dispute :submit_evidence</.hint>

      <div :if={@notice} role="status" class="alert alert-success py-2" data-testid="files-notice">
        {@notice}
      </div>
      <div :if={@error} role="alert" class="alert alert-error py-2" data-testid="files-error">
        {@error}
      </div>

      <form
        id="files-upload"
        phx-change="validate"
        phx-submit="upload"
        phx-target={@myself}
        class="card bg-base-200"
        data-testid="files-upload-form"
      >
        <div class="card-body gap-3">
          <.live_file_input
            upload={@uploads.evidence}
            class="file-input file-input-sm"
            data-testid="files-input"
          />
          <div
            :for={entry <- @uploads.evidence.entries}
            class="flex items-center gap-2 text-sm"
            data-testid="files-entry"
          >
            <span class="font-mono">{entry.client_name}</span>
            <progress class="progress w-32" value={entry.progress} max="100"></progress>
            <span
              :for={error <- upload_errors(@uploads.evidence, entry)}
              class="text-error"
              data-testid="files-entry-error"
            >
              {upload_error(error)}
            </span>
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="cancel"
              phx-value-ref={entry.ref}
              phx-target={@myself}
              aria-label="Remove"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <p
            :for={error <- upload_errors(@uploads.evidence)}
            class="text-sm text-error"
            data-testid="files-entry-error"
          >
            {upload_error(error)}
          </p>
          <div>
            <button
              class="btn btn-sm btn-primary"
              phx-disable-with="Uploading..."
              data-testid="files-upload"
            >
              <.icon name="hero-arrow-up-tray" class="size-4" /> Upload to Stripe
            </button>
          </div>
        </div>
      </form>

      <div :if={@file} class="card bg-base-200 border border-primary/40" data-testid="files-result">
        <div class="card-body gap-3">
          <dl class="grid grid-cols-2 gap-y-1 text-sm max-w-xl">
            <dt class="opacity-70">File id</dt>
            <dd class="font-mono text-xs" data-testid="file-id">{@file.id}</dd>
            <dt class="opacity-70">Name</dt>
            <dd data-testid="file-name">{@file.filename}</dd>
            <dt class="opacity-70">Size</dt>
            <dd data-testid="file-size">{size(@file.size)}</dd>
            <dt class="opacity-70">Type</dt>
            <dd data-testid="file-type">{@file.type}</dd>
            <dt class="opacity-70">Public link</dt>
            <dd>
              <a
                :if={@link}
                href={@link.url}
                target="_blank"
                class="link link-primary break-all"
                data-testid="file-link"
              >
                {@link.url}
              </a>
              <span :if={@link_error} class="text-error" data-testid="file-link-error">{@link_error}</span>
            </dd>
          </dl>

          <form
            id="files-attach"
            phx-submit="attach"
            phx-target={@myself}
            class="join"
            data-testid="file-attach-form"
          >
            <select
              name="dispute"
              class="select select-sm join-item"
              data-testid="file-attach-dispute"
            >
              <option value="">Choose an open dispute</option>
              <option :for={dispute <- @disputes} value={dispute.id}>
                {dispute.provider_id} · {dispute.reason}
              </option>
            </select>
            <button
              class="btn btn-sm join-item"
              phx-disable-with="Asking Stripe..."
              data-testid="file-attach-submit"
            >
              Attach as evidence
            </button>
          </form>
          <p :if={@disputes == []} class="text-xs opacity-70" data-testid="file-attach-none">
            No open dispute. Pay with 4000 0000 0000 0259 to make one.
          </p>
        </div>
      </div>
    </section>
    """
  end

  defp open_disputes(tenant) do
    Dispute
    |> Ash.Query.filter(
      tenant == ^tenant and
        status in [:needs_response, :warning_needs_response, :under_review, :warning_under_review]
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(20)
    |> Ash.read!(authorize?: false)
  end

  defp size(nil), do: "–"
  defp size(bytes) when bytes < 1024, do: "#{bytes} bytes"
  defp size(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"

  defp upload_error(:too_large), do: "Too big: Stripe takes up to 5 MB."
  defp upload_error(:not_accepted), do: "Only PNG, JPEG or PDF."
  defp upload_error(:too_many_files), do: "One file at a time."
  defp upload_error(error), do: "Cannot upload: #{error}."
end
