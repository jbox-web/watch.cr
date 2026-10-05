require "../spec_helper"

# A native backend that cannot start, as when the kernel refuses a watch.
class RefusedBackend < Watch::Backend
  def run(stop : Channel(Nil), &_block : Watch::Event ->) : Nil
    raise Watch::Unavailable.new("refused for the spec")
  end
end

# A backend whose run returns though nobody asked it to stop.
class ReturningBackend < Watch::Backend
  getter runs = 0

  def run(stop : Channel(Nil), &_block : Watch::Event ->) : Nil
    @runs += 1
  end
end

# A backend that crashes every time it runs.
class CrashingBackend < Watch::Backend
  getter runs = 0

  def run(stop : Channel(Nil), &_block : Watch::Event ->) : Nil
    @runs += 1
    raise "boom"
  end
end

# Emits its events once, then waits to be stopped.
class EmittingBackend < Watch::Backend
  def initialize(@events : Array(Watch::Event))
  end

  def run(stop : Channel(Nil), &block : Watch::Event ->) : Nil
    @events.each { |event| block.call(event) }
    stop.receive?
  end
end

# The Watcher picks a backend, falls back or gives up when the native one is
# unavailable, restarts one that crashed or returned on its own, and keeps
# delivering when the consumer raises on an event.
Spectator.describe Watch::Watcher do
  let(tmp_dir) { "/tmp/watch-watcher-#{Random::Secure.hex(4)}" }
  let(filter) { md_filter([tmp_dir]) }

  before_each { Dir.mkdir_p(tmp_dir) }
  after_each { FileUtils.rm_rf(tmp_dir) }

  # Runs *watcher* in a fiber; returns the stop channel and a channel fired
  # when run returns.
  private def start(watcher : Watch::Watcher, &block : Watch::Event ->)
    stop = Channel(Nil).new
    done = Channel(Nil).new(1)
    spawn do
      watcher.run(stop, &block)
    ensure
      done.send(nil)
    end
    {stop, done}
  end

  private def returned?(done : Channel(Nil), within = 2.seconds) : Bool
    select
    when done.receive
      true
    when timeout(within)
      false
    end
  end

  private def native(backend : Watch::Backend)
    ->(_filter : Watch::Filter) { backend.as(Watch::Backend) }
  end

  it "delivers the backend's events, coalesced, and returns once stopped" do
    path = File.join(tmp_dir, "a.md")
    backend = EmittingBackend.new([Watch::Event.new(path, Watch::Event::Kind::Added),
                                   Watch::Event.new(path, Watch::Event::Kind::Changed)])
    watcher = Watch::Watcher.new(filter, mode: Watch::Mode::Native, coalesce: 50.milliseconds, native: native(backend))
    seen = Channel(Watch::Event).new(8)
    stop, done = start(watcher) { |event| seen.send(event) }
    received = select
    when event = seen.receive
      event
    when timeout(2.seconds)
      nil
    end
    expect(received).to eq(Watch::Event.new(path, Watch::Event::Kind::Changed))
    stop.close
    expect(returned?(done)).to be_true
  end

  it "falls back to polling under Auto when the native backend is unavailable" do
    fallbacks = [] of String
    started = [] of String
    watcher = Watch::Watcher.new(filter, mode: Watch::Mode::Auto, poll_interval: 100.milliseconds,
      native: native(RefusedBackend.new))
    watcher.on_fallback { |ex| fallbacks << ex.message.to_s }
    watcher.on_start { |backend| started << Watch.backend_name(backend) }
    seen = Channel(Watch::Event).new(8)
    stop, done = start(watcher) { |event| seen.send(event) }
    sleep 300.milliseconds
    File.write(File.join(tmp_dir, "polled.md"), "x")
    received = select
    when event = seen.receive
      event.path
    when timeout(3.seconds)
      nil
    end
    stop.close
    expect(returned?(done)).to be_true
    expect(fallbacks).to eq(["refused for the spec"])
    expect(started).to eq(["RefusedBackend", "Poll"])
    expect(received).to eq(File.join(tmp_dir, "polled.md"))
  end

  it "ends the watch under Native when the native backend is unavailable, without polling" do
    unavailable = [] of String
    started = [] of String
    watcher = Watch::Watcher.new(filter, mode: Watch::Mode::Native, native: native(RefusedBackend.new))
    watcher.on_unavailable { |ex| unavailable << ex.message.to_s }
    watcher.on_start { |backend| started << Watch.backend_name(backend) }
    _stop, done = start(watcher) { |_event| }
    expect(returned?(done)).to be_true
    expect(unavailable).to eq(["refused for the spec"])
    expect(started).to eq(["RefusedBackend"])
  end

  it "never builds a native backend under Poll" do
    built = false
    build = ->(_filter : Watch::Filter) do
      built = true
      RefusedBackend.new.as(Watch::Backend)
    end
    watcher = Watch::Watcher.new(filter, mode: Watch::Mode::Poll, poll_interval: 100.milliseconds, native: build)
    stop, done = start(watcher) { |_event| }
    sleep 200.milliseconds
    stop.close
    expect(returned?(done)).to be_true
    expect(built).to be_false
  end

  it "restarts a backend that returned on its own after a pause, not in a tight loop" do
    backend = ReturningBackend.new
    restarts = 0
    watcher = Watch::Watcher.new(filter, mode: Watch::Mode::Native, native: native(backend))
    watcher.on_restart { |_backend| restarts += 1 }
    stop, done = start(watcher) { |_event| }
    sleep 1500.milliseconds
    stop.close
    expect(returned?(done)).to be_true
    expect(backend.runs).to be <= 3
    expect(restarts).to be >= 1
  end

  it "reports a crashed backend and restarts it after a pause" do
    backend = CrashingBackend.new
    errors = [] of String
    watcher = Watch::Watcher.new(filter, mode: Watch::Mode::Native, native: native(backend))
    watcher.on_error { |ex| errors << ex.message.to_s }
    stop, done = start(watcher) { |_event| }
    sleep 1500.milliseconds
    stop.close
    expect(returned?(done)).to be_true
    expect(backend.runs).to be_within(1).of(2)
    expect(errors.first?).to eq("boom")
  end

  it "keeps delivering after the consumer raised on an event" do
    a = File.join(tmp_dir, "a.md")
    b = File.join(tmp_dir, "b.md")
    backend = EmittingBackend.new([Watch::Event.new(a, Watch::Event::Kind::Added),
                                   Watch::Event.new(b, Watch::Event::Kind::Added)])
    failed = [] of String
    watcher = Watch::Watcher.new(filter, mode: Watch::Mode::Native, coalesce: 20.milliseconds, native: native(backend))
    watcher.on_event_error { |event, _ex| failed << event.path }
    seen = Channel(String).new(8)
    stop, done = start(watcher) do |event|
      raise "consumer failure" if event.path == a
      seen.send(event.path)
    end
    received = select
    when path = seen.receive
      path
    when timeout(2.seconds)
      nil
    end
    stop.close
    expect(returned?(done)).to be_true
    expect(received).to eq(b)
    expect(failed).to eq([a])
  end

  # Every other example injects its backend: this one is the only proof the
  # default compiles and picks the platform's own.
  it "runs the platform's native backend when none is injected" do
    started = [] of String
    watcher = Watch::Watcher.new(filter)
    watcher.on_start { |backend| started << Watch.backend_name(backend) }
    stop, done = start(watcher) { |_event| }
    sleep 200.milliseconds
    stop.close
    expect(returned?(done)).to be_true
    {% if flag?(:darwin) %}
      expect(started).to eq(["FSEvents"])
    {% elsif flag?(:linux) %}
      expect(started).to eq(["Inotify"])
    {% end %}
  end

  # A raising on_event_error used to kill the delivery fiber: nobody drained
  # the events any more, the backend blocked once the backlog filled, and run
  # never returned.
  it "keeps delivering, and still stops, when on_event_error itself raises" do
    events = (1..6).map { |index| Watch::Event.new(File.join(tmp_dir, "#{index}.md"), Watch::Event::Kind::Added) }
    backend = EmittingBackend.new(events)
    watcher = Watch::Watcher.new(filter, mode: Watch::Mode::Native, coalesce: 10.milliseconds,
      backlog: 1, native: native(backend))
    watcher.on_event_error { |_event, _ex| raise "callback failure" }
    seen = Channel(String).new(8)
    stop, done = start(watcher) do |event|
      raise "consumer failure" if event.path.ends_with?("1.md")
      seen.send(event.path)
    end
    received = [] of String
    5.times do
      select
      when path = seen.receive
        received << path
      when timeout(2.seconds)
        break
      end
    end
    stop.close
    expect(returned?(done)).to be_true
    expect(received.size).to eq(5)
  end
end
