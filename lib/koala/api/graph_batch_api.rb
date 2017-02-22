require 'koala/api'
require 'koala/api/batch_operation'

module Koala
  module Facebook
    # @private
    class GraphBatchAPI < API
      # inside a batch call we can do anything a regular Graph API can do
      include GraphAPIMethods

      # Limits from @see https://developers.facebook.com/docs/marketing-api/batch-requests/v2.8
      MAX_CALLS = 50

      attr_reader :original_api
      def initialize(api)
        super(api.access_token, api.app_secret)
        @original_api = api
      end

      def batch_calls
        @batch_calls ||= []
      end

      def graph_call_in_batch(path, args = {}, verb = "get", options = {}, &post_processing)
        # normalize options for consistency
        options = Koala::Utils.symbolize_hash(options)

        # for batch APIs, we queue up the call details (incl. post-processing)
        batch_calls << BatchOperation.new(
          :url => path,
          :args => args,
          :method => verb.downcase,
          :access_token => options[:access_token] || access_token,
          :http_options => options,
          :post_processing => post_processing
        )
        nil # batch operations return nothing immediately
      end

      # redefine the graph_call method so we can use this API inside the batch block
      # just like any regular Graph API
      alias_method :graph_call_outside_batch, :graph_call
      alias_method :graph_call, :graph_call_in_batch

      # execute the queued batch calls. limits it to 50 requests per call.
      # NOTE: if you use `name` and JsonPath references, you should ensure to call `execute` for each
      # co-reference group and that the group size is not greater than the above limits.
      #
      def execute(http_options = {})
        return [] unless batch_calls.length > 0

        batch_result = []
        requeued = Hash.new { |h, k| h[k] = 1 }
        batch_calls.each_slice(MAX_CALLS) do |batch|
          # Turn the call args collected into what facebook expects
          args = {}
          args['batch'] = JSON.dump(batch.map { |batch_op|
            args.merge!(batch_op.files) if batch_op.files
            batch_op.to_batch_params(access_token, app_secret)
          })

          graph_call_outside_batch('/', args, 'post', http_options) do |response|
            unless response
              # Facebook sometimes reportedly returns an empty body at times
              # see https://github.com/arsduo/koala/issues/184
              raise BadFacebookResponse.new(200, '', "Facebook returned an empty body")
            end

            response.each_with_index do |call_result, index|
              # Get the options hash
              batch_op = batch[index]
              index += 1

              raw_result = nil
              if call_result
                parsed_headers = if call_result.has_key?('headers')
                  call_result['headers'].inject({}) { |headers, h| headers[h['name']] = h['value']; headers}
                else
                  {}
                end

                if (error = check_response(call_result['code'], call_result['body'].to_s, parsed_headers))
                  raw_result = error
                else
                  # (see note in regular api method about JSON parsing)
                  body = JSON.parse("[#{call_result['body'].to_s}]")[0]

                  # Get the HTTP component they want
                  raw_result = case batch_op.http_options[:http_component]
                  when :status
                    call_result["code"].to_i
                  when :headers
                    # facebook returns the headers as an array of k/v pairs, but we want a regular hash
                    parsed_headers
                  else
                    body
                  end
                end

                # turn any results that are pageable into GraphCollections
                # and pass to post-processing callback if given
                result = GraphCollection.evaluate(raw_result, @original_api)
                if batch_op.post_processing
                  batch_result << batch_op.post_processing.call(result)
                else
                  batch_result << result
                end
              elsif requeued[batch_op] < 3
                # DON'T submit Log call to koala as it uses a logging pkg koala doesn't use
                Log.warn("No response for #{batch_op}. Requeuing")
                requeued[batch_op] += 1
                batch_calls << batch_op
              elsif batch_op.post_processing
                batch_result << batch_op.post_processing.call(Koala::Facebook::ClientError.new(404, '', 'No response from FB'))
              else
                batch_result << Koala::Facebook::ClientError.new(404, '', 'No response from FB')
              end
            end
          end
        end
        batch_result
      end

    end
  end
end
