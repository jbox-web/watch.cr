require "../spec_helper"

# One editor save is several events — created, written, renamed over — and
# each used to cost a re-index. The coalescer folds the events of one path
# within a window into one, and keeps accepting events while indexing runs.
Spectator.describe Watch::Coalescer do
  alias Kind = Watch::Event::Kind

  let(window) { 300.milliseconds }

  private def event(path : String, kind : Kind)
    Watch::Event.new(path, kind)
  end

  # Runs the coalescer over *input* in a fiber; returns the output channel and
  # a channel that fires when run returns.
  private def start(input : Channel(Watch::Event), delay = Time::Span.zero)
    output = Channel(Watch::Event).new(256)
    done = Channel(Nil).new(1)
    spawn do
      Watch::Coalescer.new(window).run(input) do |coalesced|
        sleep delay unless delay.zero?
        output.send(coalesced)
      end
    ensure
      done.send(nil)
    end
    {output, done}
  end

  private def drain(output, span = 1.second)
    seen = [] of Watch::Event
    deadline = Time.instant + span
    loop do
      remaining = deadline - Time.instant
      break if remaining <= Time::Span.zero
      select
      when coalesced = output.receive
        seen << coalesced
      when timeout(remaining)
        break
      end
    end
    seen
  end

  it "folds the events of one path within the window into one, carrying the last kind" do
    input = Channel(Watch::Event).new
    output, _done = start(input)
    input.send(event("/docs/a.md", Kind::Added))
    input.send(event("/docs/a.md", Kind::Changed))
    input.send(event("/docs/a.md", Kind::Deleted))

    expect(drain(output)).to eq([event("/docs/a.md", Kind::Deleted)])
    input.close
  end

  it "keeps the events of distinct paths apart" do
    input = Channel(Watch::Event).new
    output, _done = start(input)
    input.send(event("/docs/a.md", Kind::Changed))
    input.send(event("/docs/b.md", Kind::Changed))

    expect(drain(output).map(&.path).sort!).to eq(["/docs/a.md", "/docs/b.md"])
    input.close
  end

  it "never blocks the producer on a slow consumer" do
    input = Channel(Watch::Event).new
    _output, _done = start(input, delay: 1.second)
    started = Time.instant
    50.times { |index| input.send(event("/docs/#{index}.md", Kind::Changed)) }
    sleep window * 2
    50.times { |index| input.send(event("/docs/late-#{index}.md", Kind::Changed)) }

    expect(Time.instant - started).to be < window * 2 + 200.milliseconds
    input.close
  end

  # Closing the input is the watch shutting down, and the daemon teardown
  # waits on it before closing the index: delivering what is pending would
  # mean one embedding call per event, each bounded only by the Ollama
  # timeout. Pending events are dropped instead — the next boot crawl picks
  # the changes up by mtime, deletions included.
  it "returns at once when the input closes, dropping what is pending" do
    input = Channel(Watch::Event).new
    output, done = start(input)
    input.send(event("/docs/a.md", Kind::Changed))
    input.close

    returned = select
    when done.receive
      true
    when timeout(100.milliseconds)
      false
    end
    expect(returned).to be_true
    expect(drain(output, 500.milliseconds)).to be_empty
  end

  # A consumer with no catch-up of its own at startup asks for the pending
  # events to be delivered rather than dropped.
  it "delivers what is pending, oldest first, when the input closes under Drain" do
    input = Channel(Watch::Event).new(16)
    output = Channel(Watch::Event).new(16)
    done = Channel(Nil).new(1)
    spawn do
      Watch::Coalescer.new(window: 10.seconds, on_close: Watch::Coalescer::OnClose::Drain).run(input) do |coalesced|
        output.send(coalesced)
      end
    ensure
      done.send(nil)
    end
    input.send(event("/r/a.md", Kind::Added))
    input.send(event("/r/b.md", Kind::Changed))
    sleep 50.milliseconds
    input.close

    returned = select
    when done.receive
      true
    when timeout(2.seconds)
      false
    end
    expect(returned).to be_true
    expect(drain(output, 200.milliseconds).map(&.path)).to eq(["/r/a.md", "/r/b.md"])
  end
end
