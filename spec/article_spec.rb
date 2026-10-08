# frozen_string_literal: true

RSpec.describe Estate::Article do
  let(:para) { "Early in every season, you hear a lot about the pace of certain teams, and this one is no exception at all." }
  # Distinct paragraphs: one repeating the one before it is dropped as a page's echo.
  let(:paras) { Array.new(6) { |i| "#{para} Paragraph #{i + 1}." } }

  it "keeps the story and leaves the page's furniture" do
    html = <<~HTML
      <html><head><meta property="og:title" content="A story"><meta property="og:image" content="/pic.jpg"><meta name="author" content="Jo Writer"></head>
      <body><nav><p>#{para} (nav)</p></nav>
      <article><h2>First half</h2>#{paras.map { |t| "<p>#{t}</p>" }.join}<div class="newsletter-signup"><p>Sign up for our newsletter.</p></div>
      <blockquote><p>"We knew," she said.</p></blockquote><p>Advertisement</p></article>
      <footer><p>#{para} (footer)</p></footer></body></html>
    HTML
    story = described_class.extract(html, "https://news.test/a/1")

    expect(story).to include(readable: true, title: "A story", byline: "Jo Writer", image_url: "https://news.test/pic.jpg")
    expect(story[:blocks].first).to eq(kind: "h", text: "First half")
    expect(story[:blocks].count { |b| b[:kind] == "p" }).to eq(6)
    expect(story[:blocks].map { |b| b[:text] }.join).not_to include("(nav)", "(footer)", "newsletter", "Advertisement")
    expect(story[:blocks].last).to eq(kind: "quote", text: "\"We knew,\" she said.")
  end

  it "reads the story from the page's data when the page itself is drawn by scripts" do
    body = Array.new(8) { |i| "#{para} Part #{i}." }.join("\n")
    html = %(<html><head><script type="application/ld+json">#{JSON.generate("@type" => "NewsArticle", "articleBody" => body)}</script></head><body><div id="app"></div></body></html>)
    story = described_class.extract(html)

    expect(story[:readable]).to be(true)
    expect(story[:blocks].size).to eq(8)
  end

  it "says so when there is too little to read (a paywall, a teaser)" do
    story = described_class.extract("<html><body><article><p>Subscribe to keep reading.</p><p>#{para}</p></article></body></html>")
    expect(story[:readable]).to be(false)
  end

  it "reads only the hosts the app names" do
    hosts = %w[espn.com mlb.com]
    expect(described_class.allowed?("https://www.espn.com/nfl/story/_/id/1", hosts: hosts)).to be(true)
    expect(described_class.allowed?("https://mlb.com/news/x", hosts: hosts)).to be(true)
    expect(described_class.allowed?("https://evil-espn.com/x", hosts: hosts)).to be(false)
    expect(described_class.allowed?("http://169.254.169.254/latest", hosts: hosts)).to be(false)
    expect(described_class.allowed?("file:///etc/passwd", hosts: hosts)).to be(false)
    expect(described_class.allowed?("not a url", hosts: hosts)).to be(false)
  end

  it "caches a failure briefly rather than refetching on every open" do
    allow(described_class).to receive(:fetch).and_raise(Errno::ECONNREFUSED)
    expect(described_class.read("https://www.espn.com/x")).to eq(readable: false, blocks: [])
    described_class.read("https://www.espn.com/x")
    expect(described_class).to have_received(:fetch).once
  end

  it "leaves the author box a page puts atop the story" do
    html = <<~HTML
      <html><body><article><ul><li class="single-author"><div class="author has-bio">Xuan ThaiOct 7, 2026, 07:42 PM ETClose Xuan Thai is a senior writer.</div></li></ul>
      #{paras.map { |t| "<p>#{t}</p>" }.join}</article></body></html>
    HTML
    story = described_class.extract(html)
    expect(story[:blocks].first[:kind]).to eq("p")
    expect(story[:blocks].map { |b| b[:text] }.join).not_to include("Xuan Thai")
  end
end
