module ActionController
  module Routing
    class Route #:nodoc:
      attr_accessor :segments, :requirements, :conditions, :optimise
      attr_reader :value_regexps

      def initialize(segments = [], requirements = {}, conditions = {})
        @segments = segments
        @requirements = requirements
        @conditions = conditions

        if !significant_keys.include?(:action) && !requirements[:action]
          @requirements[:action] = "index"
          @significant_keys << :action
        end

        # Routes cannot use the current string interpolation method
        # if there are user-supplied <tt>:requirements</tt> as the interpolation
        # code won't raise RoutingErrors when generating
        has_requirements = @segments.detect { |segment| segment.respond_to?(:regexp) && segment.regexp }
        if has_requirements || @requirements.keys.to_set != Routing::ALLOWED_REQUIREMENTS_FOR_OPTIMISATION
          @optimise = false
        else
          @optimise = true
        end

        @value_regexps = Hash.new { |h, re| h[re] = Regexp.new("\\A#{re.to_s}\\Z") }
      end

      # Indicates whether the routes should be optimised with the string interpolation
      # version of the named routes methods.
      def optimise?
        @optimise && ActionController::Base::optimise_named_routes
      end

      def segment_keys
        segments.collect do |segment|
          segment.key if segment.respond_to? :key
        end.compact
      end

      def required_segment_keys
        required_segments = segments.select {|seg| (!seg.optional? && !seg.is_a?(DividerSegment)) || seg.is_a?(PathSegment) }
        required_segments.collect { |seg| seg.key if seg.respond_to?(:key)}.compact
      end

      # Build a query string from the keys of the given hash. If +only_keys+
      # is given (as an array), only the keys indicated will be used to build
      # the query string. The query string will correctly build array parameter
      # values.
      def build_query_string(hash, only_keys = nil)
        elements = []

        (only_keys || hash.keys).each do |key|
          if value = hash[key]
            elements << value.to_query(key)
          end
        end

        elements.empty? ? '' : "?#{elements.sort * '&'}"
      end

      # A route's parameter shell contains parameter values that are not in the
      # route's path, but should be placed in the recognized hash.
      #
      # For example, +{:controller => 'pages', :action => 'show'} is the shell for the route:
      #
      #   map.connect '/page/:id', :controller => 'pages', :action => 'show', :id => /\d+/
      #
      def parameter_shell
        @parameter_shell ||= returning({}) do |shell|
          requirements.each do |key, requirement|
            shell[key] = requirement unless requirement.is_a? Regexp
          end
        end
      end

      # Return an array containing all the keys that are used in this route. This
      # includes keys that appear inside the path, and keys that have requirements
      # placed upon them.
      def significant_keys
        @significant_keys ||= returning([]) do |sk|
          segments.each { |segment| sk << segment.key if segment.respond_to? :key }
          sk.concat requirements.keys
          sk.uniq!
        end
      end

      # Return a hash of key/value pairs representing the keys in the route that
      # have defaults, or which are specified by non-regexp requirements.
      def defaults
        @defaults ||= returning({}) do |hash|
          segments.each do |segment|
            next unless segment.respond_to? :default
            hash[segment.key] = segment.default unless segment.default.nil?
          end
          requirements.each do |key,req|
            next if Regexp === req || req.nil?
            hash[key] = req
          end
        end
      end

      def matches_controller_and_action?(controller, action)
        prepare_matching!
        (@controller_requirement.nil? || @controller_requirement === controller) &&
        (@action_requirement.nil? || @action_requirement === action)
      end

      def to_s
        @to_s ||= begin
          segs = segments.inject("") { |str,s| str << s.to_s }
          "%-6s %-40s %s" % [(conditions[:method] || :any).to_s.upcase, segs, requirements.inspect]
        end
      end

      # TODO: Route should be prepared and frozen on initialize
      def freeze
        unless frozen?
          write_recognition!
          prepare_matching!

          parameter_shell
          significant_keys
          defaults
          to_s
        end

        super
      end

      def generate(options, hash, expire_on = {})
        path, hash = generate_raw(options, hash, expire_on)
        append_query_string(path, hash, extra_keys(options))
      end

      def generate_extras(options, hash, expire_on = {})
        path, hash = generate_raw(options, hash, expire_on)
        [path, extra_keys(options)]
      end

      private
        def requirement_for(key)
          if requirements.include?(key)
            requirements[key]
          elsif segment = segments.find { |s| s.respond_to?(:key) && s.key == key }
            segment.regexp
          end
        end

        def generate_raw(options, hash, expire_on = {})
          unless requirements_met?(options, hash)
            [nil, hash]
          else
            expired = false
            values = {}

            segments.each do |segment|
              if segment.is_a?(DynamicSegment)
                value = segment.extract_value(hash)
                values[segment.key] = value
                return nil, nil unless segment.matches?(value)

                if !expired && expire_on[segment.key]
                  expired, hash = true, options
                end
              end
            end

            segs = segments.dup
            [segs.pop.generate_path(segs, values), hash]
          end
        end

        def requirements_met?(options, hash)
          requirements.all? do |key, req|
            if req.is_a? Regexp
              hash[key] && value_regexps[req] =~ options[key]
            else
              hash[key] == req
            end
          end
        end

        # Write and compile a +recognize+ method for this Route.
        def write_recognition!
          # Create an if structure to extract the params from a match if it occurs.
          body = "params = parameter_shell.dup\n#{recognition_extraction * "\n"}\nparams"
          body = "if #{recognition_conditions.join(" && ")}\n#{body}\nend"

          # Build the method declaration and compile it
          method_decl = "def recognize(path, env = {})\n#{body}\nend"
          instance_eval method_decl, "generated code (#{__FILE__}:#{__LINE__})"
          method_decl
        end

        # Plugins may override this method to add other conditions, like checks on
        # host, subdomain, and so forth. Note that changes here only affect route
        # recognition, not generation.
        def recognition_conditions
          result = ["(match = #{Regexp.new(recognition_pattern).inspect}.match(path))"]
          result << "[conditions[:method]].flatten.include?(env[:method])" if conditions[:method]
          result
        end

        # Build the regular expression pattern that will match this route.
        def recognition_pattern(wrap = true)
          pattern = ''
          segments.reverse_each do |segment|
            pattern = segment.build_pattern pattern
          end
          wrap ? ("\\A" + pattern + "\\Z") : pattern
        end

        # Write the code to extract the parameters from a matched route.
        def recognition_extraction
          next_capture = 1
          extraction = segments.collect do |segment|
            x = segment.match_extraction(next_capture)
            next_capture += segment.number_of_captures
            x
          end
          extraction.compact
        end

        # Generate the query string with any extra keys in the hash and append
        # it to the given path, returning the new path.
        def append_query_string(path, hash, query_keys = nil)
          return nil unless path
          query_keys ||= extra_keys(hash)
          "#{path}#{build_query_string(hash, query_keys)}"
        end

        # Determine which keys in the given hash are "extra". Extra keys are
        # those that were not used to generate a particular route. The extra
        # keys also do not include those recalled from the prior request, nor
        # do they include any keys that were implied in the route (like a
        # <tt>:controller</tt> that is required, but not explicitly used in the
        # text of the route.)
        def extra_keys(hash, recall = {})
          (hash || {}).keys.map { |k| k.to_sym } - (recall || {}).keys - significant_keys
        end

        def prepare_matching!
          unless defined? @matching_prepared
            @controller_requirement = requirement_for(:controller)
            @action_requirement = requirement_for(:action)
            @matching_prepared = true
          end
        end
    end
  end
end
