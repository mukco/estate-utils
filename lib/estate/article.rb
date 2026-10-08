# frozen_string_literal: true

require "net/http"
require "digest"
require "json"
require "uri"
require "nokogiri"

module Estate
  # A news story read inside the app instead of handed to iOS's Safari panel,
  # where nothing said this was still the app. Family Hub's Paper::Article
  # (2026-10-07), moved here so the sports apps' news readers are the same
  # reader rather than three copies of it.
  #
  # The publisher's page is fetched once and boiled down to what a reader
  # reads: the headline, the picture, who wrote it, and the body as plain
  # paragraphs, headings, quotes and list items — text only, never the page's
  # own markup. Navigation, share bars, "related", newsletters and ads go.
  #
  # Not every page gives itself up: a paywall, or a page drawn by its scripts,
  # leaves too little text, and the answer says so (readable: false) so the
  # app offers the original instead. Kept a week; a failure an hour.
  #
  # The caller decides which addresses may be read (`allowed?` with its own
  # news hosts): this must never be a way to have a server fetch any page
  # anybody names.
  module Article
    USER_AGENT = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    HOPS = 4
    MAX_BYTES = 4_000_000
    KEEP = 7 * 24 * 3600
    RETRY = 3600
    OPEN_TIMEOUT = 4
    READ_TIMEOUT = 8
    # Codes that mean "not you" rather than "not here": worth asking again
    # from the proxy's address.
    REFUSALS = [ 401, 402, 403, 406, 409, 418, 429, 451 ].freeze
    # Enough of a story to be worth reading here, not a teaser.
    ENOUGH_CHARS = 600
    ENOUGH_BLOCKS = 3

    # ESPN puts the writer's photo, name, date and bio in a list item atop the
    # story ("Xuan ThaiOct 7, 2026, 07:42 PM ETClose…"); the byline is in meta.
    NOISE = /author|byline|contributor|dateline|timestamp|comment|share|social|newsletter|related|promo|subscribe|advert|sponsor|footer|sidebar|breadcrumb|nav|menu|cookie|consent|paywall|signup|sign-up|recirc|trending|most-popular|outbrain|taboola/i
    BOILERPLATE = /\A(advertisement|ad|sponsored|subscribe|sign up|read more|related|share this|follow us|click here|listen to this article)\b/i
    # Filler a page leaves inside the story's own box.
    FILLER = /native ad|get our latest .* in your inbox|sign up for .* newsletter/i

    module_function

    # Whether `url` is an http(s) address on one of `hosts` (or a subdomain).
    def allowed?(url, hosts:)
      uri = URI.parse(url.to_s)
      return false unless %w[http https].include?(uri.scheme) && uri.host

      host = uri.host.downcase
      hosts.any? { |h| host == h || host.end_with?(".#{h}") }
    rescue URI::InvalidURIError
      false
    end

    # { title:, site:, byline:, image_url:, published_at:, blocks: [{kind:, text:}], readable: }
    def read(url)
      key = "estate/article:v2:#{Digest::SHA256.hexdigest(url)}"
      cached = store&.read(key)
      return cached if cached

      result = extract(fetch(url), url)
      store&.write(key, result, expires_in: result[:readable] ? KEEP : RETRY)
      result
    rescue StandardError => e
      Estate::Cache.logger.warn("[article] #{url.to_s[0, 60]}: #{e.class}")
      failed = { readable: false, blocks: [] }
      store&.write(key, failed, expires_in: RETRY) if key
      failed
    end

    # Direct first; when the site refuses this server's address (ESPN's empty
    # 202, a 403) again through the WARP proxy. As a browser: a news page is
    # written for one.
    def fetch(url)
      raise ArgumentError, "not a web address" unless %w[http https].include?(URI.parse(url).scheme)

      body, refused = attempt(url, nil, HOPS)
      body, = attempt(url, proxy, HOPS) if body.nil? && refused && proxy
      body = body.to_s
      body.bytesize > MAX_BYTES ? body.byteslice(0, MAX_BYTES) : body
    end

    def attempt(url, via, hops)
      uri = URI(url)
      http = via ? Net::HTTP.new(uri.host, uri.port, via.host, via.port) : Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      res = http.get(uri.request_uri, "User-Agent" => USER_AGENT, "Accept" => "text/html")
      case res
      when Net::HTTPSuccess
        res.body.to_s.strip.empty? ? [ nil, true ] : [ res.body, false ]
      when Net::HTTPRedirection
        loc = res["location"].to_s
        return [ nil, false ] if loc.empty? || hops <= 0

        attempt(URI.join(url, loc).to_s, via, hops - 1)
      else
        [ nil, REFUSALS.include?(res.code.to_i) ]
      end
    rescue Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ECONNRESET
      [ nil, true ]
    end

    def proxy
      raw = [ ENV["ARTICLE_PROXY_URL"], ENV["FEED_PROXY_URL"], ENV["HTTPS_PROXY"], ENV["https_proxy"] ].find { |v| v && !v.empty? }
      raw && URI(raw)
    rescue URI::InvalidURIError
      nil
    end

    # The pure part: a page's HTML in, the story out.
    def extract(html, url = nil)
      doc = Nokogiri::HTML(html.to_s)
      meta = ->(*names) { names.lazy.map { |n| doc.at_css("meta[property='#{n}'], meta[name='#{n}']")&.[]("content") }.find { |v| v && !v.strip.empty? } }
      found = {
        title: meta.("og:title", "twitter:title") || doc.at_css("title")&.text.to_s.strip.then { |t| t.empty? ? nil : t },
        site: meta.("og:site_name"),
        byline: meta.("author", "article:author", "parsely-author").then { |a| a.nil? || a.start_with?("http") ? nil : a },
        image_url: absolute(meta.("og:image", "twitter:image"), url),
        published_at: meta.("article:published_time", "parsely-pub-date")
      }

      # Many news pages carry the whole story as data for search engines
      # (articleBody) even when the page itself is drawn by its scripts.
      embedded = embedded_body(doc)

      doc.css("script, style, noscript, nav, header, footer, aside, form, iframe, svg, button, figcaption, [aria-hidden='true'], [role='navigation'], [role='complementary']").remove
      doc.css("[class], [id]").each do |node|
        node.remove if "#{node['class']} #{node['id']}".match?(NOISE) && node.css("p").sum { |p| p.text.length } < 400
      end

      body = container(doc)
      blocks = body ? blocks_of(body) : []
      chars = blocks.sum { |b| b[:kind] == "p" ? b[:text].length : 0 }
      if embedded.sum(&:length) > chars * 1.3
        blocks = embedded.map { |t| { kind: "p", text: t } }
        chars = embedded.sum(&:length)
      end
      found.merge(blocks: blocks, readable: chars >= ENOUGH_CHARS && blocks.count { |b| b[:kind] == "p" } >= ENOUGH_BLOCKS)
    end

    # articleBody from the page's JSON-LD, as paragraphs: by its own line
    # breaks, or — written as one run — every few sentences.
    def embedded_body(doc)
      bodies = doc.css("script[type='application/ld+json']").flat_map do |s|
        data = JSON.parse(s.text) rescue nil
        # One object, a list of them, or a "@graph" holding them — never
        # Array(hash), which would turn one object into its key/value pairs.
        list = data.is_a?(Hash) && data["@graph"].is_a?(Array) ? data["@graph"] : data.is_a?(Array) ? data : [ data ]
        list.filter_map { |d| d.is_a?(Hash) ? d["articleBody"] : nil }
      end
      text = bodies.map(&:to_s).max_by(&:length).to_s
      return [] if text.length < ENOUGH_CHARS

      parts = text.split(/\n\s*\n|\n/).map { |t| t.gsub(/\s+/, " ").strip }.reject(&:empty?)
      parts = text.gsub(/\s+/, " ").strip.split(/(?<=[.!?”"])\s+(?=[A-Z“"])/).each_slice(3).map { |s| s.join(" ") } if parts.size < 3
      parts.first(200)
    end

    # The story's own box: the <article> with the most paragraph text, else
    # whichever element holds the most paragraph text directly beneath it.
    def container(doc)
      articles = doc.css("article, [itemprop='articleBody'], main")
      best = articles.max_by { |a| a.css("p").sum { |p| p.text.strip.length } }
      return best if best && best.css("p").sum { |p| p.text.strip.length } >= ENOUGH_CHARS

      scores = Hash.new(0)
      doc.css("p").each { |p| scores[p.parent] += p.text.strip.length if p.parent }
      scores.max_by { |_, v| v }&.first
    end

    def blocks_of(body)
      out = []
      body.css("p, h2, h3, blockquote, li").each do |node|
        # A paragraph inside a quote or a list item is said once, by its holder.
        next if node.name == "p" && node.ancestors.any? { |a| %w[blockquote li].include?(a.name) }
        next if node.name == "li" && node.ancestors("nav, footer").any?

        text = node.text.gsub(/\s+/, " ").strip
        next if text.empty? || text.match?(BOILERPLATE) || text.match?(FILLER)

        kind = { "h2" => "h", "h3" => "h", "blockquote" => "quote", "li" => "li" }.fetch(node.name, "p")
        next if kind == "h" && text.length > 140
        next if kind == "p" && text.length < 25 && !text.match?(/[.!?”"]\z/)
        next if kind == "li" && text.length < 15
        next if out.last && out.last[:text] == text

        out << { kind: kind, text: text }
      end
      out.first(200)
    end

    def absolute(src, base)
      return nil if src.nil? || src.empty?

      base ? URI.join(base, src).to_s : src
    rescue URI::InvalidURIError
      nil
    end

    def store
      Estate::Cache.store
    rescue StandardError
      nil
    end
  end
end
