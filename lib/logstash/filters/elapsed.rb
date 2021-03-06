# elapsed filter
#
# This filter tracks a pair of start/end events and calculates the elapsed
# time between them.

require "logstash/filters/base"
require "logstash/namespace"
require 'thread'
require 'socket'


# The elapsed filter tracks a pair of start/end events and uses their
# timestamps to calculate the elapsed time between them.
#
# The filter has been developed to track the execution time of processes and
# other long tasks.
#
# The configuration looks like this:
# [source,ruby]
#     filter {
#       elapsed {
#         start_tag => "start event tag"
#         end_tag => "end event tag"
#         unique_id_field => "id field name"
#         unique_id_fields => ["id field name", "second id field name"]
#         timeout => seconds
#         new_event_on_match => true/false
#         embed_inbetween_messages => true/false
#       }
#     }
#
# The events managed by this filter must have some particular properties.
# The event describing the start of the task (the "start event") must contain
# a tag equal to `start_tag`. On the other side, the event describing the end
# of the task (the "end event") must contain a tag equal to `end_tag`. Both
# these two kinds of event need to own an ID field which identify uniquely that
# particular task. The name of this field is stored in `unique_id_field`.
#
# You can use a Grok filter to prepare the events for the elapsed filter.
# An example of configuration can be:
# [source,ruby]
#     filter {
#       grok {
#         match => ["message", "%{TIMESTAMP_ISO8601} START FROM (?<task_id_ip>%{IP:ip}) id: (?<task_id>.*)"]
#         add_tag => [ "taskStarted" ]
#       }
#
#       grok {
#         match => ["message", "%{TIMESTAMP_ISO8601} END FROM (?<task_id_ip>%{IP:ip}) id: (?<task_id>.*)"]
#         add_tag => [ "taskTerminated"]
#       }
#
#       elapsed {
#         start_tag => "taskStarted"
#         end_tag => "taskTerminated"
#         unique_id_field => "task_id"
#         unique_id_fields => ["task_id", "task_id_ip"]
#       }
#     }
#
# The elapsed filter collects all the "start events". If two, or more, "start
# events" have the same ID, only the first one is recorded, the others are
# discarded.
#
# When an "end event" matching a previously collected "start event" is
# received, there is a match. The configuration property `new_event_on_match`
# tells where to insert the elapsed information: they can be added to the
# "end event" or a new "match event" can be created. Both events store the
# following information:
#
# * the tags `elapsed` and `elapsed.match`
# * the field `elapsed.time` with the difference, in seconds, between
#   the two events timestamps
# * an ID filed with the task ID
# * the field `elapsed.timestamp_start` with the timestamp of the start event
#
# If the "end event" does not arrive before "timeout" seconds, the
# "start event" is discarded and an "expired event" is generated. This event
# contains:
#
# * the tags `elapsed` and `elapsed.expired_error`
# * a field called `elapsed.time` with the age, in seconds, of the
#   "start event"
# * an ID filed with the task ID
# * the field `elapsed.timestamp_start` with the timestamp of the "start event"
#
class LogStash::Filters::Elapsed < LogStash::Filters::Base
  PREFIX = "elapsed."
  ELAPSED_FIELD = PREFIX + "time"
  TIMESTAMP_START_EVENT_FIELD = PREFIX + "timestamp_start"
  HOST_FIELD = "host"

  ELAPSED_TAG = "elapsed"
  EXPIRED_ERROR_TAG = PREFIX + "expired_error"
  END_WITHOUT_START_TAG = PREFIX + "end_wtihout_start"
  MATCH_TAG = PREFIX + "match"

  config_name "elapsed"

  # The name of the tag identifying the "start event"
  config :start_tag, :validate => :string, :required => true

  # The name of the tag identifying the "end event"
  config :end_tag, :validate => :string, :required => true

  # The name of the field containing the task ID.
  # This value must uniquely identify the task in the system, otherwise
  # it's impossible to match the couple of events.
  config :unique_id_field, :validate => :string, :required => false

  # The names of the fields containing the task IDs
  # Just for the case one key is not unique or key is constructed in runtime
  config :unique_id_fields, :validate => :array, :required => false

  # The amount of seconds after an "end event" can be considered lost.
  # The corresponding "start event" is discarded and an "expired event"
  # is generated. The default value is 30 minutes (1800 seconds).
  config :timeout, :validate => :number, :required => false, :default => 1800

  # This property manage what to do when an "end event" matches a "start event".
  # If it's set to `false` (default value), the elapsed information are added
  # to the "end event"; if it's set to `true` a new "match event" is created.
  config :new_event_on_match, :validate => :boolean, :required => false, :default => false

  # As useful information can be present between start_tag and end_tag, there
  # is the option to collect all messages which where read after start_tag and push them
  # into ['between'] tag
  # Default is false
  config :embed_inbetween_messages, :validate => :boolean, :required => false, :default => false


  public
  def register
    @mutex = Mutex.new
    # This is the state of the filter. The keys are the "unique_id_field",
    # the values are couples of values: <start event, age>
    @start_events = {}
    @between_events = []

    @logger.info("Elapsed, timeout: #{@timeout} seconds")
  end

  # Getter method used for the tests
  def start_events
    @start_events
  end

  def filter(event)
    return unless filter?(event)
    
    unique_id = ""

    if @unique_id_fields != nil && @unique_id_fields.size > 0
       @unique_id_field = ""
       @unique_id_fields.each{ |el| 
		if event[el].nil?
			if @embed_inbetween_messages	
				ev2 = LogStash::Filters::Elapsed::Element.new(event)
				@between_events.push(ev2.event)
			end
			return 
		end
		unique_id = unique_id + event[el]
		@unique_id_field = @unique_id_field + el
	}
    else
        unique_id = event[@unique_id_field]
   end

    return if unique_id.nil?

    if(start_event?(event))
      filter_matched(event)
      @logger.info("Elapsed, 'start event' received", start_tag: @start_tag, unique_id_field: @unique_id_field)

      @mutex.synchronize do
        unless(@start_events.has_key?(unique_id))
          @start_events[unique_id] = LogStash::Filters::Elapsed::Element.new(event)
        end
      end

    elsif(end_event?(event))
      filter_matched(event)
      @logger.info("Elapsed, 'end event' received", end_tag: @end_tag, unique_id_field: @unique_id_field)

      @mutex.lock
      if(@start_events.has_key?(unique_id))
        start_event = @start_events.delete(unique_id).event
        @mutex.unlock
        elapsed = event["@timestamp"] - start_event["@timestamp"]
        if(@new_event_on_match)
          elapsed_event = new_elapsed_event(elapsed, unique_id, start_event["@timestamp"])
	  if @embed_inbetween_messages && @unique_id_fields != nil && @unique_id_fields.size > 0
		  elapsed_event["between"] = @between_events.join(' ')
		  @between_events = []
	  end
          filter_matched(elapsed_event)
          yield elapsed_event if block_given?
        else
          return add_elapsed_info(event, elapsed, unique_id, start_event["@timestamp"])
        end
      else
        @mutex.unlock
        # The "start event" did not arrive.
        event.tag(END_WITHOUT_START_TAG)
      end
    end
  end # def filter

  # The method is invoked by LogStash every 5 seconds.
  def flush(options = {})
    expired_elements = []

    @mutex.synchronize do
      increment_age_by(5)
      expired_elements = remove_expired_elements()
    end

    return create_expired_events_from(expired_elements)
  end

  private
  def increment_age_by(seconds)
    @start_events.each_pair do |key, element|
      element.age += seconds
    end
  end

  # Remove the expired "start events" from the internal
  # buffer and return them.
  def remove_expired_elements()
    expired = []
    @start_events.delete_if do |key, element|
      if(element.age >= @timeout)
        expired << element
        next true
      end
      next false
    end

    return expired
  end

  def create_expired_events_from(expired_elements)
    events = []
    expired_elements.each do |element|
      error_event = LogStash::Event.new
      error_event.tag(ELAPSED_TAG)
      error_event.tag(EXPIRED_ERROR_TAG)

      error_event[HOST_FIELD] = Socket.gethostname
      error_event[@unique_id_field] = element.event[@unique_id_field]
      error_event[ELAPSED_FIELD] = element.age
      error_event[TIMESTAMP_START_EVENT_FIELD] = element.event["@timestamp"]

      events << error_event
      filter_matched(error_event)
    end

    return events
  end

  def start_event?(event)
    return (event["tags"] != nil && event["tags"].include?(@start_tag))
  end

  def end_event?(event)
    return (event["tags"] != nil && event["tags"].include?(@end_tag))
  end

  def new_elapsed_event(elapsed_time, unique_id, timestamp_start_event)
      new_event = LogStash::Event.new
      new_event[HOST_FIELD] = Socket.gethostname
      return add_elapsed_info(new_event, elapsed_time, unique_id, timestamp_start_event)
  end

  def add_elapsed_info(event, elapsed_time, unique_id, timestamp_start_event)
      event.tag(ELAPSED_TAG)
      event.tag(MATCH_TAG)

      event[ELAPSED_FIELD] = elapsed_time
      event[@unique_id_field] = unique_id
      event[TIMESTAMP_START_EVENT_FIELD] = timestamp_start_event

      return event
  end
end # class LogStash::Filters::Elapsed

class LogStash::Filters::Elapsed::Element
  attr_accessor :event, :age

  def initialize(event)
    @event = event
    @age = 0
  end
end
