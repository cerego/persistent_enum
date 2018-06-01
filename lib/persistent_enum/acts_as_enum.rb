# frozen_string_literal: true

require "active_support"
require "active_record"

module PersistentEnum
  module ActsAsEnum
    extend ActiveSupport::Concern

    class State
      attr_reader :enum_spec, :by_name, :by_name_insensitive, :by_ordinal, :required_by_ordinal
      delegate :required_members, :name_attr, :sql_enum_type, to: :enum_spec

      def initialize(enum_spec, enum_values, required_enum_constants)
        @enum_spec = enum_spec

        enum_values.each do |val|
          val.attributes.each_value { |attr| attr.freeze }
          val.freeze
        end

        @by_ordinal = enum_values.index_by(&:ordinal).freeze

        @by_name    = enum_values
                        .index_by { |v| v.read_attribute(enum_spec.name_attr) }
                        .with_indifferent_access
                        .freeze

        @by_name_insensitive = enum_values
                                 .index_by { |v| v.read_attribute(enum_spec.name_attr).downcase }
                                 .with_indifferent_access
                                 .freeze

        @required_by_ordinal = required_enum_constants
                                 .map { |name| by_name.fetch(name) }
                                 .index_by(&:ordinal)
                                 .freeze

        @insensitive_lookup  = (by_name.size == by_name_insensitive.size)

        freeze
      end

      def insensitive_lookup?
        @insensitive_lookup
      end
    end

    module ClassMethods
      # Overridden in singleton classes to close over acts-as-enum state in an
      # subclassing-safe way.
      def _acts_as_enum_state
        nil
      end

      def initialize_acts_as_enum(enum_spec)
        prev_state = _acts_as_enum_state

        if self.methods(false).include?(:_acts_as_enum_state)
          singleton_class.class_eval do
            remove_method(:_acts_as_enum_state)
          end
        end

        ActsAsEnum.register_acts_as_enum(self) if prev_state.nil?

        required_values = PersistentEnum.cache_constants(
          self,
          enum_spec.required_members,
          name_attr:     enum_spec.name_attr,
          sql_enum_type: enum_spec.sql_enum_type)

        required_enum_constants = required_values.map { |val| val.read_attribute(enum_spec.name_attr) }

        # Now we've ensured that our required constants are present, load the rest
        # of the enum from the database (if present)
        all_values = required_values.dup
        if table_exists?
          all_values.concat(unscoped { where.not(id: required_values) })
        end

        # Normalize values: If we already have a equal value in the previous
        # state, we want to use that rather than a new copy of it
        all_values.map! do |value|
          if prev_state.present? && (prev_value = prev_state.by_name[name]) == value
            prev_value
          else
            value
          end
        end

        state = State.new(enum_spec, all_values, required_enum_constants)

        singleton_class.class_eval do
          define_method(:_acts_as_enum_state) { state }
        end

        before_destroy { raise ActiveRecord::ReadOnlyRecord }
      end

      def reinitialize_acts_as_enum
        current_state = _acts_as_enum_state
        raise "Cannot refresh acts_as_enum type #{self.name}: not already initialized!" if current_state.nil?
        initialize_acts_as_enum(current_state.enum_spec)
      end

      def dummy_class
        PersistentEnum.dummy_class(self, name_attr)
      end

      def [](index)
        _acts_as_enum_state.by_ordinal[index]
      end

      def value_of(name, insensitive: false)
        if insensitive
          unless _acts_as_enum_state.insensitive_lookup?
            raise RuntimeError.new("#{self.name} constants are case-dependent: cannot perform case-insensitive lookup")
          end
          _acts_as_enum_state.by_name_insensitive[name.downcase]
        else
          _acts_as_enum_state.by_name[name]
        end
      end

      def value_of!(name, insensitive: false)
        v = value_of(name, insensitive: insensitive)
        raise NameError.new("#{self}: Invalid member '#{name}'") unless v.present?
        v
      end

      alias with_name value_of

      # Currently active ordinals
      def ordinals
        _acts_as_enum_state.required_by_ordinal.keys
      end

      # Currently active enum members
      def values
        _acts_as_enum_state.required_by_ordinal.values
      end

      def active?(member)
        _acts_as_enum_state.required_by_ordinal.has_key?(member.ordinal)
      end

      # All ordinals, including of inactive enum members
      def all_ordinals
        _acts_as_enum_state.by_ordinal.keys
      end

      # All enum members, including inactive
      def all_values
        _acts_as_enum_state.by_ordinal.values
      end

      def name_attr
        _acts_as_enum_state.name_attr
      end
    end

    # Enum values should not be mutable: allow creation and modification only
    # before the state has been initialized.
    def readonly?
      !self.class._acts_as_enum_state.nil?
    end

    def enum_constant
      read_attribute(self.class.name_attr)
    end

    def to_sym
      enum_constant.to_sym
    end

    def ordinal
      read_attribute(:id)
    end


    # Is this enum member still present in the enum declaration?
    def active?
      self.class.active?(self)
    end

    class << self
      KNOWN_ENUMERATIONS = {}
      LOCK = Monitor.new

      def register_acts_as_enum(clazz)
        LOCK.synchronize do
          KNOWN_ENUMERATIONS[clazz.name] = clazz
        end
      end

      # Reload enumerations from the database: useful if the database contents
      # may have changed (e.g. fixture loading).
      def reinitialize_enumerations
        LOCK.synchronize do
          KNOWN_ENUMERATIONS.each_value do |clazz|
            clazz.reinitialize_acts_as_enum
          end
        end
      end

      # Ensure that all KNOWN_ENUMERATIONS are loaded by resolving each name
      # constant and reregistering the resulting class. Raises NameError if a
      # previously-encountered type cannot be resolved.
      def rerequire_known_enumerations
        LOCK.synchronize do
          KNOWN_ENUMERATIONS.keys.each do |name|
            new_clazz = name.safe_constantize
            unless new_clazz.is_a?(Class)
              raise NameError.new("Could not resolve ActsAsEnum type '#{name}' after reload")
            end
            register_acts_as_enum(new_clazz)
          end
        end
      end
    end
  end
end
