module Org
  module MarkdownHelper
    def self.render(str)
      if RUBY_PLATFORM == 'java'
        render_kramdown(str)
      else
        render_redcarpet(str)
      end
    end

    private

    def self.render_kramdown(str)
      Kramdown::Document.new(str, input: 'GFM').to_html
    end

    def self.render_redcarpet(str)
      renderer = Redcarpet::Markdown.new(
        Redcarpet::Render::HTML.new({
          with_toc_data: true
        }),
        Slim::Embedded.default_options[:markdown]
      )

      # Redcarpet now allows a new renderer to be defined. This would be better.
      renderer.render(str).
        gsub /<code class="(\w+)">/, %q|<code class="language-\1">|
    end
  end
end
