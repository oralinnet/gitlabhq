module Banzai
  module Filter
    # Issues, Merge Requests, Snippets, Commits and Commit Ranges share
    # similar functionality in reference filtering.
    class AbstractReferenceFilter < ReferenceFilter
      include CrossProjectReference

      def self.object_class
        # Implement in child class
        # Example: MergeRequest
      end

      def self.object_name
        @object_name ||= object_class.name.underscore
      end

      def self.object_sym
        @object_sym ||= object_name.to_sym
      end

      def self.data_reference
        @data_reference ||= "data-#{object_name.dasherize}"
      end

      def self.object_class_title
        @object_title ||= object_class.name.titleize
      end

      # Public: Find references in text (like `!123` for merge requests)
      #
      #   AnyReferenceFilter.references_in(text) do |match, id, project_ref, matches|
      #     object = find_object(project_ref, id)
      #     "<a href=...>#{object.to_reference}</a>"
      #   end
      #
      # text - String text to search.
      #
      # Yields the String match, the Integer referenced object ID, an optional String
      # of the external project reference, and all of the matchdata.
      #
      # Returns a String replaced with the return of the block.
      def self.references_in(text, pattern = object_class.reference_pattern)
        text.gsub(pattern) do |match|
          yield match, $~[object_sym].to_i, $~[:project], $~
        end
      end

      def self.referenced_by(node)
        { object_sym => LazyReference.new(object_class, node.attr(data_reference)) }
      end

      def object_class
        self.class.object_class
      end

      def object_sym
        self.class.object_sym
      end

      def object_class_title
        self.class.object_class_title
      end

      def references_in(*args, &block)
        self.class.references_in(*args, &block)
      end

      def find_object(project, id)
        # Implement in child class
        # Example: project.merge_requests.find
      end

      def find_object_cached(project, id)
        if RequestStore.active?
          cache = find_objects_cache[object_class][project.id]

          get_or_set_cache(cache, id) { find_object(project, id) }
        else
          find_object(project, id)
        end
      end

      def project_from_ref_cache(ref)
        if RequestStore.active?
          cache = project_refs_cache

          get_or_set_cache(cache, ref) { project_from_ref(ref) }
        else
          project_from_ref(ref)
        end
      end

      def url_for_object(object, project)
        # Implement in child class
        # Example: project_merge_request_url
      end

      def url_for_object_cached(object, project)
        if RequestStore.active?
          cache = url_for_object_cache[object_class][project.id]

          get_or_set_cache(cache, object) { url_for_object(object, project) }
        else
          url_for_object(object, project)
        end
      end

      def call
        return doc if project.nil?

        ref_pattern = object_class.reference_pattern
        link_pattern = object_class.link_reference_pattern

        each_node do |node|
          if text_node?(node) && ref_pattern
            replace_text_when_pattern_matches(node, ref_pattern) do |content|
              object_link_filter(content, ref_pattern)
            end

          elsif element_node?(node)
            yield_valid_link(node) do |link, text|
              if ref_pattern && link =~ /\A#{ref_pattern}\z/
                replace_link_node_with_href(node, link) do
                  object_link_filter(link, ref_pattern, link_text: text)
                end

                next
              end

              next unless link_pattern

              if link == text && text =~ /\A#{link_pattern}/
                replace_link_node_with_text(node, link) do
                  object_link_filter(text, link_pattern)
                end

                next
              end

              if link =~ /\A#{link_pattern}\z/
                replace_link_node_with_href(node, link) do
                  object_link_filter(link, link_pattern, link_text: text)
                end

                next
              end
            end
          end
        end

        doc
      end

      # Replace references (like `!123` for merge requests) in text with links
      # to the referenced object's details page.
      #
      # text - String text to replace references in.
      # pattern - Reference pattern to match against.
      # link_text - Original content of the link being replaced.
      #
      # Returns a String with references replaced with links. All links
      # have `gfm` and `gfm-OBJECT_NAME` class names attached for styling.
      def object_link_filter(text, pattern, link_text: nil)
        references_in(text, pattern) do |match, id, project_ref, matches|
          project = project_from_ref_cache(project_ref)

          if project && object = find_object_cached(project, id)
            title = object_link_title(object)
            klass = reference_class(object_sym)

            data  = data_attribute(
              original:     link_text || match,
              project:      project.id,
              object_sym => object.id
            )

            if matches.names.include?("url") && matches[:url]
              url = matches[:url]
            else
              url = url_for_object_cached(object, project)
            end

            text = link_text || object_link_text(object, matches)

            %(<a href="#{url}" #{data}
                 title="#{escape_once(title)}"
                 class="#{klass}">#{escape_once(text)}</a>)
          else
            match
          end
        end
      end

      def object_link_text_extras(object, matches)
        extras = []

        if matches.names.include?("anchor") && matches[:anchor] && matches[:anchor] =~ /\A\#note_(\d+)\z/
          extras << "comment #{$1}"
        end

        extras
      end

      def object_link_title(object)
        "#{object_class_title}: #{object.title}"
      end

      def object_link_text(object, matches)
        text = object.reference_link_text(context[:project])

        extras = object_link_text_extras(object, matches)
        text += " (#{extras.join(", ")})" if extras.any?

        text
      end

      private

      def project_refs_cache
        RequestStore[:banzai_project_refs] ||= {}
      end

      def find_objects_cache
        RequestStore[:banzai_find_objects_cache] ||= Hash.new do |hash, key|
          hash[key] = Hash.new { |h, k| h[k] = {} }
        end
      end

      def url_for_object_cache
        RequestStore[:banzai_url_for_object] ||= Hash.new do |hash, key|
          hash[key] = Hash.new { |h, k| h[k] = {} }
        end
      end

      def get_or_set_cache(cache, key)
        if cache.key?(key)
          cache[key]
        else
          cache[key] = yield
        end
      end
    end
  end
end
