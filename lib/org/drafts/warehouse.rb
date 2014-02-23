module Org
  class Articles
    article "/warehouse", {
#      hook:         <<-eos,
#When building an app against an API, do you pull in their SDK or just make raw HTTP calls? Here are a few reasons that I don't want your SDK in production.
#      eos
      location:     "San Francisco",
      published_at: Time.parse("Wed Feb 12 22:25:57 PST 2014"),
      signature:    true,
      title:        "The Humble Data Warehouse",
    } do
      render_article do
        slim :"articles/signature", layout: !pjax?
      end
    end
  end
end
