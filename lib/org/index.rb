module Org
  class Index < Sinatra::Base
    configure do
      set :views, Config.root + "/views"
    end

    helpers Helpers::Common
    helpers Helpers::Goodreads
    helpers Helpers::Twitter

    get "/" do
      if json?
        content_type :json
        MultiJson.encode({
          links: [
            { rel: "articles",        href: "#{request.url}articles" },
            { rel: "favors",          href: "#{request.url}favors" },
            { rel: "humans",          href: "#{request.url}humans.txt" },
            { rel: "lies",            href: "#{request.url}lies" },
            { rel: "reading",         href: "#{request.url}reading" },
            { rel: "talks",           href: "#{request.url}talks" },
            { rel: "that-sunny-dome", href: "#{request.url}that-sunny-dome" },
            { rel: "twitter",         href: "#{request.url}twitter" },
          ]
        }, pretty: true)
      else
        events = DB[:events].reverse_order(:occurred_at)
        @books    = events.filter(type: "goodreads").limit(10).all
        @essays   = Articles.articles
        @links    = events.filter(type: "readability").limit(10).all
        @photos   = events.filter(type: "flickr").
          filter("metadata -> 'medium_width' = '500'").limit(5)
        @tweets   = events.filter(type: "twitter").
          filter("metadata -> 'reply' = 'false'").limit(10)
        slim :"index"
      end
    end

    not_found do
      404
    end

    private

    def json?
      request.preferred_type("application/json", "text/html") ==
        "application/json"
    end
  end
end
