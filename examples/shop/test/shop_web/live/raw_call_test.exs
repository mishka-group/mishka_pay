defmodule ShopWeb.RawCallTest do
  use ShopWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ShopWeb.StripeStub

  setup do
    test = self()

    StripeStub.stub(fn
      "GET", "/v1/tax/settings", params ->
        send(test, {:asked, params})
        %{"object" => "tax.settings", "status" => "pending"}

      _method, _path, _params ->
        nil
    end)

    :ok
  end

  test "reads nothing until sent, then shows Stripe's own answer with the options asked for",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    refute_received {:asked, _params}
    refute has_element?(view, "[data-testid=raw-call-answer]")

    view
    |> form("[data-testid=raw-call-form]", %{
      path: "/v1/tax/settings",
      expand: "head_office, defaults",
      api_version: ""
    })
    |> render_submit()

    render_async(view)

    assert_received {:asked, %{"expand" => ["head_office", "defaults"]}}
    assert has_element?(view, "[data-testid=raw-call-answer]", "tax.settings")
    refute has_element?(view, "[data-testid=raw-call-reading]")
  end

  test "a path that is not a plain API path is refused before anything is sent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    for path <- ["//evil.com", "https://evil.com/x", "../v1/balance"] do
      view
      |> form("[data-testid=raw-call-form]", %{path: path, expand: "", api_version: ""})
      |> render_submit()

      render_async(view)
      assert has_element?(view, "[data-testid=raw-call-error]", "path")
      refute has_element?(view, "[data-testid=raw-call-answer]")
    end

    refute_received {:asked, _params}
  end
end
