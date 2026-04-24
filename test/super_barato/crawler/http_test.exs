defmodule SuperBarato.Crawler.HttpTest do
  use ExUnit.Case, async: true

  alias SuperBarato.Crawler.Http
  alias SuperBarato.Crawler.Http.Response

  describe "blocked?/1" do
    test "307 (Akamai redirect to /blocked) is blocked" do
      assert Http.blocked?(%Response{status: 307})
    end

    test "403 is blocked" do
      assert Http.blocked?(%Response{status: 403})
    end

    test "429 is blocked" do
      assert Http.blocked?(%Response{status: 429})
    end

    test "503 is blocked" do
      assert Http.blocked?(%Response{status: 503})
    end

    test "200 with 'Robot or human?' body is blocked" do
      body = ~s(<html><head><title>Robot or human?</title></head></html>)
      assert Http.blocked?(%Response{status: 200, body: body})
    end

    test "200 with Akamai 'Access Denied' body is blocked" do
      body = ~s(<HTML><HEAD>\n<TITLE>Access Denied</TITLE>\n</HEAD>)
      assert Http.blocked?(%Response{status: 200, body: body})
    end

    test "body starting with 'blocked - redirecting' is blocked" do
      assert Http.blocked?(%Response{status: 200, body: "blocked - redirecting"})
    end

    test "200 with normal JSON body is not blocked" do
      refute Http.blocked?(%Response{status: 200, body: ~s([{"id":1}])})
    end

    test "200 with empty body is not blocked" do
      refute Http.blocked?(%Response{status: 200, body: ""})
    end

    test "404 and 500 (non-block statuses) are not blocked" do
      refute Http.blocked?(%Response{status: 404})
      refute Http.blocked?(%Response{status: 500})
    end

    test "a body merely mentioning 'robot' is not blocked" do
      refute Http.blocked?(%Response{status: 200, body: "I am not a robot, probably"})
    end
  end

  describe "binary_for_profile/1" do
    test "resolves atom profile to priv/bin path" do
      path = Http.binary_for_profile(:chrome107)
      assert String.ends_with?(path, "/curl_chrome107")
    end

    test "passes through binary paths unchanged" do
      assert Http.binary_for_profile("/custom/curl_ff117") == "/custom/curl_ff117"
    end
  end

  describe "known_profiles/0" do
    test "includes chrome116 (default) and chrome107 (Lider)" do
      profiles = Http.known_profiles()
      assert :chrome116 in profiles
      assert :chrome107 in profiles
    end
  end
end
