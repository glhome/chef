require 'set'
require 'yajl'
require 'fast_xs'
require 'em-http-request'
require 'opscode/expander/loggable'
require 'opscode/expander/flattener'

module Opscode
  module Expander
    class Solrizer

      @active_http_requests = Set.new

      def self.http_request_started(instance)
        @active_http_requests << instance
      end

      def self.http_request_completed(instance)
        @active_http_requests.delete(instance)
      end

      def self.http_requests_active?
        !@active_http_requests.empty?
      end

      def self.clear_http_requests
        @active_http_requests.clear
      end

      include Loggable

      ADD     = "add"
      DELETE  = "delete"
      SKIP    = "skip"

      ITEM        = "item"
      ID          = "id"
      TYPE        = "type"
      DATABASE    = "database"
      ENQUEUED_AT = "enqueued_at"

      DATA_BAG_ITEM = "data_bag_item"
      DATA_BAG      = "data_bag"

      X_CHEF_id_CHEF_X        = 'X_CHEF_id_CHEF_X'
      X_CHEF_database_CHEF_X  = 'X_CHEF_database_CHEF_X'
      X_CHEF_type_CHEF_X      = 'X_CHEF_type_CHEF_X'

      CONTENT_TYPE_XML = {"Content-Type" => "text/xml"}

      attr_reader :action

      attr_reader :indexer_payload

      attr_reader :chef_object

      attr_reader :obj_id

      attr_reader :obj_type

      attr_reader :database

      attr_reader :enqueued_at

      def initialize(object_command_json, &on_completion_block)
        @start_time = Time.now.to_f
        @on_completion_block = on_completion_block
        if parsed_message    = parse(object_command_json)
          @action           = parsed_message["action"]
          @indexer_payload  = parsed_message["payload"]

          extract_object_fields if @indexer_payload
        else
          @action = SKIP
        end
      end

      def extract_object_fields
        @chef_object = @indexer_payload[ITEM]
        @database    = @indexer_payload[DATABASE]
        @obj_id      = @indexer_payload[ID]
        @obj_type    = @indexer_payload[TYPE]
        @enqueued_at = @indexer_payload[ENQUEUED_AT]
        @data_bag = @obj_type == DATA_BAG_ITEM ? @chef_object[DATA_BAG] : nil
      end

      def parse(serialized_object)
        Yajl::Parser.parse(serialized_object)
      rescue Yajl::ParseError
        log.error { "cannot index object because it is invalid JSON: #{serialized_object}" }
      end

      def run
        case @action
        when ADD
          add
        when DELETE
          delete
        when SKIP
          completed
          log.info { "not indexing this item because of malformed JSON"}
        else
          completed
          log.error { "cannot index object becuase it has an invalid action #{@action}" }
        end
      end

      def add
        post_to_solr(pointyize_add, 0) do
          ["indexed #{indexed_object}",
           "transit,xml,solr-post |",
           [transit_time, @xml_time, @solr_post_time].join(","),
           "|"
          ].join(" ")
        end
      rescue Exception => e
        log.error { "#{e.class.name}: #{e.message}\n#{e.backtrace.join("\n")}"}
      end

      def delete
        post_to_solr(pointyize_delete, 0) { "deleted #{indexed_object} transit-time[#{transit_time}s]"}
      rescue Exception => e
        log.error { "#{e.class.name}: #{e.message}\n#{e.backtrace.join("\n")}"}
      end

      def flattened_object
        flattened_object = Flattener.new(@chef_object).flattened_item
 
        flattened_object[X_CHEF_id_CHEF_X]        = [@obj_id]
        flattened_object[X_CHEF_database_CHEF_X]  = [@database]
        flattened_object[X_CHEF_type_CHEF_X]      = [@obj_type]

        log.debug {"adding flattened object to Solr: #{flattened_object.inspect}"}

        flattened_object
      end

      START_XML   = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      ADD_DOC     = "<add><doc>"
      DELETE_DOC  = "<delete>"
      ID_OPEN     = "<id>"
      ID_CLOSE    = "</id>"
      END_ADD_DOC = "</doc></add>\n"
      END_DELETE  = "</delete>\n"
      START_CONTENT = '<field name="content">'
      CLOSE_FIELD = "</field>"

      FLD_CHEF_ID_FMT = '<field name="X_CHEF_id_CHEF_X">%s</field>'
      FLD_CHEF_DB_FMT = '<field name="X_CHEF_database_CHEF_X">%s</field>'
      FLD_CHEF_TY_FMT = '<field name="X_CHEF_type_CHEF_X">%s</field>'
      FLD_DATA_BAG    = '<field name="data_bag">%s</field>'

      KEYVAL_FMT = "%s__=__%s "

      # Takes a flattened hash where the values are arrays and converts it into
      # a dignified XML document suitable for POST to Solr.
      # The general structure of the output document is like this:
      #   <?xml version="1.0" encoding="UTF-8"?>
      #   <add>
      #     <doc>
      #       <field name="content">
      #           key__=__value
      #           key__=__another_value
      #           other_key__=__yet another value
      #       </field>
      #     </doc>
      #   </add>
      # The document as generated has minimal newlines and formatting, however.
      def pointyize_add
        xml = ""
        xml << START_XML << ADD_DOC
        xml << (FLD_CHEF_ID_FMT % @obj_id)
        xml << (FLD_CHEF_DB_FMT % @database)
        xml << (FLD_CHEF_TY_FMT % @obj_type)
        xml << START_CONTENT
        content = ""
        flattened_object.each do |field, values|
          values.each do |v|
            content << (KEYVAL_FMT % [field, v])
          end
        end
        xml << content.fast_xs
        xml << CLOSE_FIELD      # ends content
        xml << (FLD_DATA_BAG % @data_bag.fast_xs) if @data_bag
        xml << END_ADD_DOC
        @xml_time = Time.now.to_f - @start_time
        xml
      end

      # Takes a succinct document id, like 2342, and turns it into something
      # even more compact, like
      #   "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<delete><id>2342</id></delete>\n"
      def pointyize_delete
        xml = ""
        xml << START_XML
        xml << DELETE_DOC
        xml << ID_OPEN
        xml << @obj_id.to_s
        xml << ID_CLOSE
        xml << END_DELETE
        xml
      end

      def post_to_solr(document, retries, &logger_block)
        log.debug("POSTing document to SOLR:\n#{document}")
        http_req = EventMachine::HttpRequest.new(solr_url).post(:body => document, :timeout => 1200, :head => CONTENT_TYPE_XML)
        http_request_started if retries == 0

        http_req.callback do
          completed if retries == 0
          if http_req.response_header.status == 200
            log.info(&logger_block)
          else
            log.error { "Failed to post to solr: #{indexed_object}" }
          end
        end
        http_req.errback do
          log.error { "Failed to post to solr (connection error): #{indexed_object}" }

          if retries < max_retries
            log.info { "Retrying solr connection in #{retry_wait} seconds: #{indexed_object} attempt #{retries}" }
            EM.add_timer(retry_wait) do
              post_to_solr(document, retries + 1, &logger_block)
            end
          end

          completed if retries == 0
        end
      end

      def completed
        @solr_post_time = Time.now.to_f - @start_time
        self.class.http_request_completed(self)
        @on_completion_block.call
      end

      def transit_time
        Time.now.utc.to_i - @enqueued_at
      end

      def solr_url
        @solr_url ||= Expander.config.solr_url + '/solr/update'
      end

      def max_retries
        @max_retries ||= Expander.config.max_retries
      end

      def retry_wait
        @retry_wait ||= Expander.config.retry_wait
      end

      def indexed_object
        "#{@obj_type}[#{@obj_id}] database[#{@database}]"
      end

      def http_request_started
        self.class.http_request_started(self)
      end

      def eql?(other)
        other.hash == hash
      end

      def hash
        "#{action}#{indexed_object}#@enqueued_at#{self.class.name}".hash
      end

    end
  end
end
