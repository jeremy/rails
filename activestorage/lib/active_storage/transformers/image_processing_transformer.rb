# frozen_string_literal: true

begin
  require "image_processing"
rescue LoadError
  raise LoadError, <<~ERROR.squish
    Generating image variants require the image_processing gem.
    Please add `gem "image_processing", "~> 2.0"` to your Gemfile.
  ERROR
end

module ActiveStorage
  module Transformers
    class ImageProcessingTransformer < Transformer
      private
        class UnsupportedImageProcessingMethod < StandardError; end
        class UnsupportedImageProcessingArgument < StandardError; end

        def process(file, format:)
          processor.
            source(file).
            loader(page: 0).
            convert(format).
            apply(operations).
            call
        end

        def operations
          transformations.each_with_object([]) do |(name, argument), list|
            validate_transformation(name, argument)

            if argument.present?
              list << [ name, argument ]
            end
          end
        end

        def validate_transformation(name, argument)
          case name.to_s
          when "combine_options"
            raise ArgumentError, <<~ERROR.squish
              Active Storage's ImageProcessing transformer doesn't support :combine_options,
              as it always generates a single command.
            ERROR
          when "apply"
            # apply re-enters the builder for each entry in its argument, so it dispatches
            # arbitrary operations (including loader/saver) regardless of any per-method check.
            # It is builder machinery, never a legitimate transformation in a variation URL.
            raise UnsupportedImageProcessingMethod, <<~ERROR.squish
              The provided transformation method is not supported: apply.
            ERROR
          when "loader", "saver"
            # A loader/saver argument is normally a Hash of options for the format's default
            # loader/saver. But a nested :loader/:saver key selects the operation by name:
            # ImageProcessing::Vips::Processor dispatches Vips::Image.public_send(:"#{loader}load")
            # / image.public_send(:"#{saver}save"). Reject that selector while still allowing
            # option hashes (e.g. loader: { page: nil }, saver: { quality: 80 }).
            if argument.is_a?(Hash) && argument.any? { |key, _| key.to_s == name.to_s }
              raise UnsupportedImageProcessingMethod, <<~ERROR.squish
                The provided transformation method is not supported: #{name} with a nested #{name} selector.
              ERROR
            end
          end
        end
    end
  end
end
