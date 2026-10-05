require "../spec_helper"

# The filter decides which paths a backend reports and which directories it
# descends into: the roots, hidden entries and exclusions are its own rules,
# everything else is the consumer's predicate.
Spectator.describe Watch::Filter do
  let(tmp_dir) { "/tmp/watch-filter-#{Random::Secure.hex(4)}" }
  let(docs) { File.join(tmp_dir, "docs") }
  let(filter) { md_filter([docs], ["**/drafts/**", "**/templates/*"]) }

  before_each { Dir.mkdir_p(docs) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  private def event(path : String, kind = Watch::Event::Kind::Changed)
    Watch::Event.new(path, kind)
  end

  it "accepts a file under a root that the predicate accepts" do
    expect(filter.accept?(event(File.join(docs, "guide.md")))).to be_true
  end

  it "rejects a file the predicate refuses" do
    expect(filter.accept?(event(File.join(docs, "diagram.png")))).to be_false
  end

  it "rejects a path under an excluded directory" do
    expect(filter.accept?(event(File.join(docs, "drafts", "wip.md")))).to be_false
  end

  it "rejects a path outside every root, including a sibling sharing its prefix" do
    expect(filter.accept?(event(File.join(tmp_dir, "elsewhere.md")))).to be_false
    expect(filter.accept?(event(File.join(tmp_dir, "docs-old", "guide.md")))).to be_false
  end

  it "never asks the predicate about a path outside the roots" do
    asked = [] of String
    counting = Watch::Filter.new([docs]) do |candidate|
      asked << candidate.path
      true
    end
    counting.accept?(event(File.join(tmp_dir, "elsewhere.md")))
    expect(asked).to be_empty
  end

  it "hands deletions to the predicate with their kind" do
    kinds = [] of Watch::Event::Kind
    seeing = Watch::Filter.new([docs]) do |candidate|
      kinds << candidate.kind
      true
    end
    seeing.accept?(event(File.join(docs, "chapter"), Watch::Event::Kind::Deleted))
    expect(kinds).to eq([Watch::Event::Kind::Deleted])
  end

  it "rejects a hidden file or a file under a hidden directory below its root" do
    expect(filter.accept?(event(File.join(docs, ".draft.md")))).to be_false
    expect(filter.accept?(event(File.join(docs, ".hidden", "note.md")))).to be_false
    expect(filter.descend?(File.join(docs, ".git"))).to be_false
  end

  it "accepts files under a root that is itself hidden" do
    hidden_root = File.join(tmp_dir, ".meta")
    expect(md_filter([hidden_root]).accept?(event(File.join(hidden_root, "guide.md")))).to be_true
  end

  # Roots are routinely written `doc/`, and File.expand_path keeps the slash:
  # a root spelled that way produced event paths with `//`.
  it "holds its roots without a trailing slash" do
    expect(md_filter(["#{docs}/"]).roots).to eq([docs])
  end

  it "holds relative roots as absolute paths" do
    expect(Watch::Filter.new(["docs"]).roots).to eq([File.join(Dir.current, "docs")])
  end

  it "accepts everything under the roots that is neither hidden nor excluded when given no predicate" do
    plain = Watch::Filter.new([docs])
    expect(plain.accept?(event(File.join(docs, "diagram.png")))).to be_true
    expect(plain.accept?(event(File.join(docs, ".hidden.png")))).to be_false
  end

  it "does not descend into a directory whose whole subtree is excluded" do
    expect(filter.descend?(File.join(docs, "drafts"))).to be_false
    expect(filter.descend?(File.join(docs, "chapter"))).to be_true
  end

  it "descends into a directory whose exclusion covers only its direct children" do
    expect(filter.descend?(File.join(docs, "templates"))).to be_true
  end

  it "attributes a path under nested roots to the longest one" do
    nested = File.join(docs, "api")
    expect(md_filter([docs, nested]).root_for(File.join(nested, "x.md"))).to eq(nested)
  end
end
