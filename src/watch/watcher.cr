require "log"

module Watch
  # How a Watcher picks its backend.
  enum Mode
    # Native file events, polling when they are unavailable.
    Auto
    # Native file events, or no watch at all.
    Native
    # Polling only.
    Poll
  end

  # The operating system's file-event backend: FSEvents on macOS, inotify on
  # Linux. Elsewhere there is none, which reads as an unavailable backend.
  #
  # Cast to Backend: the return restriction does not widen the inferred type,
  # so a proc wrapping this call would otherwise be typed by the concrete
  # class and refuse to stand in for a `Proc(Filter, Backend)`.
  def self.native_backend(filter : Filter) : Backend
    {% if flag?(:darwin) %}
      FSEvents.new(filter).as(Backend)
    {% elsif flag?(:linux) %}
      Inotify.new(filter).as(Backend)
    {% else %}
      raise Unavailable.new("no native file events on this platform")
    {% end %}
  end

  # The backend's class name without its namespace: `Inotify`, `FSEvents`,
  # `Poll`.
  def self.backend_name(backend : Backend) : String
    backend.class.name.split("::").last
  end

  # Runs a backend over a filter until stopped, and delivers its events
  # through a Coalescer, so one editor save costs one delivery and a slow
  # consumer never stalls the backend.
  #
  # A native backend that cannot run raises Unavailable: under Auto the watch
  # falls back to polling, under Native it ends. Any other crash is reported
  # and the backend restarted after a short pause, and so is a backend that
  # returns though nobody asked it to stop.
  #
  # Nothing is logged above debug unless a callback is left at its default:
  # what a consumer must see goes through the callbacks, which default to
  # logging through `Log.for("watch")`.
  class Watcher
    Log = ::Log.for("watch")

    # Events waiting for the coalescer. It reads continuously, so this only
    # absorbs a burst while it takes its lock.
    DEFAULT_BACKLOG = 4096

    # Pause before restarting a backend that crashed or returned on its own:
    # restarting at once spun the loop billions of times a minute.
    RESTART_PAUSE = 1.second

    @on_start : Proc(Backend, Nil) = ->(backend : Backend) { Log.debug { "watching with #{Watch.backend_name(backend)}" } }
    @on_fallback : Proc(Unavailable, Nil) = ->(ex : Unavailable) { Log.warn { "native file events unavailable (#{ex.message}); polling" } }
    @on_unavailable : Proc(Unavailable, Nil) = ->(ex : Unavailable) { Log.error { "native file events unavailable (#{ex.message}); no watch" } }
    @on_restart : Proc(Backend, Nil) = ->(backend : Backend) { Log.warn { "#{Watch.backend_name(backend)} stopped on its own, restarting" } }
    @on_error : Proc(Exception, Nil) = ->(ex : Exception) { Log.error { "watch crashed, restarting: [#{ex.class}] #{ex.message}" } }
    @on_event_error : Proc(Event, Exception, Nil) = ->(event : Event, ex : Exception) { Log.error { "failed handling #{event.path}: [#{ex.class}] #{ex.message}" } }

    # *native* builds the native backend, replaceable in specs.
    def initialize(@filter : Filter, @mode : Mode = Mode::Auto, @poll_interval : Time::Span = 1.second,
                   @coalesce : Time::Span = Coalescer::DEFAULT_WINDOW,
                   @on_close : Coalescer::OnClose = Coalescer::OnClose::Drop,
                   @backlog : Int32 = DEFAULT_BACKLOG,
                   @native : Proc(Filter, Backend) = ->(f : Filter) { Watch.native_backend(f) })
    end

    # Called each time a backend is about to run, including a native one that
    # then turns out to be unavailable: native backends find that out in `run`.
    def on_start(&block : Backend ->) : Nil
      @on_start = block
    end

    # Called under Auto when the native backend is unavailable, just before
    # the watch switches to polling.
    def on_fallback(&block : Unavailable ->) : Nil
      @on_fallback = block
    end

    # Called under Native when the native backend is unavailable; the watch
    # then ends.
    def on_unavailable(&block : Unavailable ->) : Nil
      @on_unavailable = block
    end

    # Called when a backend returned though nobody asked it to stop; it is
    # restarted after a pause.
    def on_restart(&block : Backend ->) : Nil
      @on_restart = block
    end

    # Called when a backend crashed; it is restarted after a pause.
    def on_error(&block : Exception ->) : Nil
      @on_error = block
    end

    # Called when the consumer's block raised on an event; delivery goes on
    # with the next one.
    def on_event_error(&block : Event, Exception ->) : Nil
      @on_event_error = block
    end

    # Watches until *stop* is closed, which ends the watch within about a
    # second with no file event needed. Returns only once the last event
    # handed to *block* is done with, so a caller may release what *block*
    # uses right after.
    def run(stop : Channel(Nil), &block : Event ->) : Nil
      mode = @mode
      poll = -> { Poll.new(@filter, @poll_interval).as(Backend) }
      events = Channel(Event).new(@backlog)
      delivered = Channel(Nil).new(1)
      on_event_error = @on_event_error
      spawn do
        Coalescer.new(@coalesce, @on_close).run(events) do |event|
          block.call(event)
        rescue ex
          report_event_error(on_event_error, event, ex)
        end
      ensure
        delivered.send(nil)
      end

      begin
        backend : Backend? = nil
        loop do
          break if stop.closed?
          begin
            # Built inside the rescue: a native backend may be unavailable
            # from the start, and Auto must fall back then too.
            current = backend ||= mode.poll? ? poll.call : @native.call(@filter)
            @on_start.call(current)
            current.run(stop) { |event| events.send(event) }
            unless stop.closed?
              # A backend is meant to run until stopped. Returning anyway is a
              # failure like a crash, and gets the same pause.
              @on_restart.call(current)
              pause(stop)
            end
          rescue ex : Unavailable
            if mode.native?
              @on_unavailable.call(ex)
              break
            end
            @on_fallback.call(ex)
            mode = Mode::Poll
            backend = poll.call
          rescue ex
            @on_error.call(ex)
            pause(stop)
          end
        end
      ensure
        # Delivered before returning: the caller may release what the block
        # uses next.
        events.close
        delivered.receive
      end
    end

    # A callback that raises must not take the delivery fiber with it: nobody
    # would drain the events any more, the backend would block once the
    # backlog filled, and `run` would never return.
    private def report_event_error(callback : Proc(Event, Exception, Nil), event : Event, ex : Exception) : Nil
      callback.call(event, ex)
    rescue error
      Log.debug { "on_event_error raised: [#{error.class}] #{error.message}" }
    end

    private def pause(stop : Channel(Nil)) : Nil
      select
      when stop.receive?
      when timeout(RESTART_PAUSE)
      end
    end
  end
end
