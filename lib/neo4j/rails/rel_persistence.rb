module Neo4j
	module Rails
		module RelPersistence
			extend ActiveSupport::Concern

      included do
        extend TxMethods
        tx_methods :destroy, :create, :update, :delete
      end


			# Persist the object to the database.  Validations and Callbacks are included
			# by default but validation can be disabled by passing :validate => false
			# to #save.
      def save(*)
      	create_or_update
      end

      # Persist the object to the database.  Validations and Callbacks are included
			# by default but validation can be disabled by passing :validate => false
			# to #save!.
			#
			# Raises a RecordInvalidError if there is a problem during save.
      def save!(*args)
				unless save(*args)
					raise RecordInvalidError.new(self)
				end
			end

			# Updates a single attribute and saves the record.
			# This is especially useful for boolean flags on existing records. Also note that
			#
			# * Validation is skipped.
			# * Callbacks are invoked.
			# * Updates all the attributes that are dirty in this object.
			#
			def update_attribute(name, value)
				respond_to?("#{name}=") ? send("#{name}=", value) : self[name] = value
				save(:validate => false)
			end

			# Removes the node from Neo4j and freezes the object.
			def destroy
				delete
				freeze
			end

			# Same as #destroy but doesn't run destroy callbacks and doesn't freeze
			# the object
			def delete
				del unless new_record?
				set_deleted_properties
			end

			# Returns true if the object was destroyed.
			def destroyed?()
        @_deleted || Neo4j::Relationship._load(id).nil?
      end

			# Updates this resource with all the attributes from the passed-in Hash and requests that the record be saved.
      # If saving fails because the resource is invalid then false will be returned.
      def update_attributes(attributes)
        self.attributes = attributes
        save
      end

      # Same as #update_attributes, but raises an exception if saving fails.
      def update_attributes!(attributes)
        self.attributes = attributes
        save!
      end

      # Reload the object from the DB.
      def reload(options = nil)
        clear_changes
        reset_attributes
        unless reload_from_database
          set_deleted_properties
          freeze
        end
        self
      end

      # Returns if the record is persisted, i.e. it’s not a new record and it was not destroyed
      def persisted?
        !new_record? && !destroyed?
      end

      # Returns true if the record hasn't been saved to Neo4j yet.
      def new_record?
        _java_rel.nil?
      end

      alias :new? :new_record?

      # Freeze the properties hash.
			def freeze
				@properties.freeze; self
			end

      # Returns +true+ if the properties hash has been frozen.
      def frozen?
        reload
        @properties.frozen?
      end

      module ClassMethods
        # Initialize a model and set a bunch of attributes at the same time.  Returns
        # the object whether saved successfully or not.
        def create(*args)
          new(*args).tap do |o|
            yield o if block_given?
            o.save
          end
        end

        # Same as #create, but raises an error if there is a problem during save.
        # Returns the object whether saved successfully or not.
        def create!(*args)
          new(*args).tap do |o|
            yield o if block_given?
            o.save!
          end
        end

        # Destroy each node in turn.  Runs the destroy callbacks for each node.
        def destroy_all
          all.each do |n|
            n.destroy
          end
        end
      end

      protected
      def create_or_update
        result = persisted? ? update : create
        unless result != false
          Neo4j::Rails::Transaction.fail if Neo4j::Rails::Transaction.running?
          false
        else
          true
        end
      end

      def update
        write_changed_attributes
        clear_changes
        true
      end

      def create()
        begin
          # prevent calling create twice
          @start_node.rm_outgoing_rel(type, self)
          @end_node.rm_incoming_rel(type, self)

          _persist_start_node
          _persist_end_node

          @_java_rel = Neo4j::Relationship.new(type, start_node, end_node)
          Neo4j::IdentityMap.add(@_java_rel, self)
          init_on_create
          clear_changes
        end unless @end_node.nil?
        true
      end

      def _load(id)
        Neo4j::Relationship.load(id)
      end

      def _persist_start_node
        unless @start_node.persisted? || @start_node.save
          # not sure if this can happen - probably a bug
          raise "Can't save start_node #{@start_node} id #{@start_node.id}"
        end
      end

      def _persist_end_node
        unless @end_node.persisted? || @end_node.save
          raise "Can't save end_node #{@end_node} id #{@end_node.id}"
        end
      end

      def init_on_create(*)
        #self["_classname"] = self.class.to_s
        write_default_attributes
        write_changed_attributes
        @_java_rel[:_classname] = self.class.to_s
      end

      def reset_attributes
        @properties = {}
      end

      def reload_from_database
        Neo4j::IdentityMap.remove_rel_by_id(id) if persisted?
        Neo4j::IdentityMap.remove_node_by_id(@end_node.id) if @end_node && @end_node.persisted?
        Neo4j::IdentityMap.remove_node_by_id(@start_node.id) if @start_node && @start_node.persisted?

        if reloaded = self.class.load(id)
          send(:attributes=, reloaded.attributes, false)
        end
        reloaded
      end

      def set_deleted_properties
        @_deleted   = true
        @_persisted = false
      end

      # Ensure any defaults are stored in the DB
      def write_default_attributes
        attribute_defaults.each do |attribute, value|
          write_attribute(attribute, Neo4j::TypeConverters.convert(value, attribute, self.class)) unless changed_attributes.has_key?(attribute) || _java_rel.has_property?(attribute)
        end
      end

      # Write attributes to the Neo4j DB only if they're altered
      def write_changed_attributes
        @properties.each do |attribute, value|
          write_attribute(attribute, value) if changed_attributes.has_key?(attribute)
        end
      end

      class RecordInvalidError < RuntimeError
        attr_reader :record

        def initialize(record)
          @record = record
          super(@record.errors.full_messages.join(", "))
        end
      end
      
    end

  end
end
