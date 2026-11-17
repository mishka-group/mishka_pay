defmodule ShopWeb.FilesTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  # The first bytes of a PNG: Stripe's adapter checks a file's bytes are its type.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 0::size(64)>>

  defp dispute(evidence) do
    MishkaPay.Test.stripe_object(:dispute, %{
      "id" => "du_1",
      "amount" => 1000,
      "currency" => "usd",
      "reason" => "fraudulent",
      "evidence" => evidence
    })
  end

  test "uploads a PNG, shows its link, and attaches it to the dispute picked, which stays picked",
       %{conn: conn} do
    test = self()

    StripeStub.stub(fn
      "POST", "/v1/files", %{"multipart" => body} ->
        send(test, {:uploaded, String.contains?(body, "dispute_evidence")})

        %{
          "id" => "file_1",
          "object" => "file",
          "purpose" => "dispute_evidence",
          "filename" => "receipt.png",
          "size" => byte_size(@png),
          "type" => "png"
        }

      "POST", "/v1/file_links", %{"file" => "file_1"} ->
        %{"id" => "link_1", "file" => "file_1", "url" => "https://files.stripe.com/links/test_1"}

      "GET", "/v1/disputes/du_1", _params ->
        dispute(%{})

      "POST", "/v1/disputes/du_1", %{"evidence" => %{"uncategorized_file" => "file_1"}} ->
        send(test, :attached)
        dispute(%{"uncategorized_file" => "file_1"})

      _method, _path, _params ->
        nil
    end)

    {:ok, _row} =
      Ash.create(Shop.Pay.Dispute, %{provider: "stripe", dispute_id: "du_1", tenant: "demo"},
        action: :sync,
        authorize?: false
      )

    {:ok, view, _html} = live(conn, "/")

    view
    |> file_input("[data-testid=files-upload-form]", :evidence, [
      %{name: "receipt.png", content: @png, type: "image/png"}
    ])
    |> render_upload("receipt.png")

    view |> form("[data-testid=files-upload-form]") |> render_submit()

    assert_received {:uploaded, true}
    assert has_element?(view, "[data-testid=file-id]", "file_1")
    assert has_element?(view, "[data-testid=file-size]", "#{byte_size(@png)} bytes")

    assert has_element?(
             view,
             "[data-testid=file-link][href='https://files.stripe.com/links/test_1']"
           )

    row = Ash.read_one!(Shop.Pay.Dispute, authorize?: false)

    view |> form("[data-testid=file-attach-form]", %{dispute: row.id}) |> render_change()
    view |> form("[data-testid=file-attach-form]") |> render_submit()

    assert_received :attached
    assert has_element?(view, "[data-testid=files-notice]", "evidence of du_1")

    view |> form("[data-testid=file-attach-form]") |> render_submit()
    assert_received :attached
  end

  test "refuses a file Stripe does not take for evidence", %{conn: conn} do
    StripeStub.stub(fn _method, _path, _params -> nil end)
    {:ok, view, _html} = live(conn, "/")

    input =
      file_input(view, "[data-testid=files-upload-form]", :evidence, [
        %{name: "notes.txt", content: "hello", type: "text/plain"}
      ])

    assert {:error, [[_ref, :not_accepted]]} = render_upload(input, "notes.txt")
    assert has_element?(view, "[data-testid=files-entry-error]", "Only PNG, JPEG or PDF.")
  end

  test "asks for a file before uploading", %{conn: conn} do
    StripeStub.stub(fn _method, _path, _params -> nil end)
    {:ok, view, _html} = live(conn, "/")

    view |> form("[data-testid=files-upload-form]") |> render_submit()
    assert has_element?(view, "[data-testid=files-error]", "Choose a PNG, JPEG or PDF first.")
  end
end
